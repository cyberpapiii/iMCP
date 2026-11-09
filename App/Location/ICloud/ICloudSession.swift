import Foundation
import Network
import OSLog

/// The last thing that went wrong, typed, so each place that shows it can
/// choose its own words.
enum ICloudFailure: Equatable, Sendable {
    case auth(ICloudAuthError)
    case findMyAuthorization(FindMyWebAuthorizationError)
    case findMy(FindMyError)
    case codeNeededToRenew
    /// Find My refused a session the password renewed minutes ago, and
    /// sending the password again so soon could cost another Apple email.
    case renewedRecently
    /// Another error with reviewed words of its own.
    case described(String)
    /// Anything else: the network, or an error with nothing safe to show.
    case unreachable

    init(_ error: Error) {
        switch error {
        case let auth as ICloudAuthError: self = .auth(auth)
        case let authorization as FindMyWebAuthorizationError: self = .findMyAuthorization(authorization)
        case let findMy as FindMyError: self = .findMy(findMy)
        case let facing as ClientFacingError:
            self = facing.errorDescription.map(Self.described) ?? .unreachable
        default: self = .unreachable
        }
    }

    var message: String {
        switch self {
        case .auth(let error): return error.errorDescription ?? Self.unreachableMessage
        case .findMyAuthorization(let error): return error.errorDescription ?? Self.unreachableMessage
        case .findMy(let error): return error.errorDescription ?? Self.unreachableMessage
        case .codeNeededToRenew:
            return
                "The iCloud session expired and Apple wants a verification code before it renews. "
                + "Open Sign in to iCloud from the iMCP menu and enter the code."
        case .renewedRecently:
            return
                "Find My refused the iCloud session minutes after iMCP renewed it. "
                + "iMCP waits five minutes before sending the password again, then renews on the next Find My call."
        case .described(let text): return text
        case .unreachable: return Self.unreachableMessage
        }
    }

    /// Apple's own errors carry request ids and internal paths, so only the
    /// shape of the failure crosses into the UI.
    private static let unreachableMessage = "Could not reach iCloud. Check your connection and try again."
}

/// The app's one iCloud session: what state it is in, and the only path from
/// signed out to signed in.
///
/// The user's password reaches `signIn` from a `SecureField` and is handed to
/// the auth client, which keeps it in the Keychain next to Apple's tokens so
/// the session can renew itself. Nothing here holds or logs it.
@MainActor
final class ICloudSession: ObservableObject {
    enum State: Equatable {
        case signedOut
        case working
        case awaitingCode(ICloudTwoFactorDelivery)
        case signedIn(accountName: String)
        /// The stored session expired. Distinct from `signedOut` so the UI can
        /// say "sign in again" instead of pretending the user never did.
        case needsReauthentication
        /// The stored session could not be restored for a reason that was
        /// not Apple's verdict, and a retry is queued. Nothing for the owner
        /// to do yet.
        case reconnecting
        /// The Keychain held a session we could not read. Distinct from
        /// `signedOut` so a new sign-in cannot overwrite tokens that are
        /// still on disk.
        case credentialsUnreadable
    }

    /// Why a session that existed stopped being usable. Recorded so the
    /// menu, the tool error, and the log can all say the same thing, and so a
    /// "signed out again" report can be answered from evidence.
    enum InvalidationReason: Equatable, CustomStringConvertible {
        /// The Keychain refused the read; the tokens may still be there.
        case credentialsUnreadable
        case restoreFailed(String)
        /// Find My rejected the session, and the account login that would
        /// have renewed it was rejected too.
        case appleRejectedStoredSession(String)
        case paused(PauseReason)

        var description: String {
            switch self {
            case .credentialsUnreadable:
                return "The Keychain could not be read."
            case .restoreFailed(let detail):
                return "The stored session could not be restored: \(detail)"
            case .appleRejectedStoredSession(let detail):
                return "Apple rejected the stored session: \(detail)"
            case .paused(let reason):
                return reason.description
            }
        }
    }

    /// Why automatic recovery is waiting. Until it ends no full password
    /// sign-in runs; see `schedulePausedPoll`.
    enum PauseReason: Equatable, Sendable, CustomStringConvertible {
        /// Apple accepted authentication but requires updated terms or
        /// another account action before Find My will answer.
        case accountRepairRequired
        /// Authentication completed, but a transient Find My failure
        /// prevented verification. Only cookie validation and Find My probes
        /// may retry.
        case verificationPending
        /// One unattended password sign-in already ran recently. Repeating it
        /// would send another Apple email without fixing the rejected session.
        case repeatedAutomaticSignInStopped

        var description: String {
            switch self {
            case .accountRepairRequired:
                return "Apple requires updated terms or another account action."
            case .verificationPending:
                return "iCloud sign-in is waiting for Find My verification."
            case .repeatedAutomaticSignInStopped:
                return "Another automatic browser sign-in was stopped to prevent repeated Apple emails."
            }
        }
    }

    /// One operation the session started, so its result can tell whether it
    /// still belongs to the phase it began in.
    struct Attempt: Equatable {
        private let id = UUID()
    }

    /// Where the session is. A live Find My client exists in exactly the
    /// phases that carry one.
    enum Phase {
        /// Nothing tried yet this launch.
        case launched
        case signedOut
        case restoring(Attempt)
        /// A manual sign-in or verification code is with Apple.
        case signingIn(Attempt)
        case awaitingCode(ICloudTwoFactorDelivery)
        case active(ICloudLiveSession)
        /// A password sign-in is renewing the session; the old client stays.
        case renewing(ICloudLiveSession)
        case paused(ICloudLiveSession?, PauseReason)
        /// A restore failed on something other than Apple's verdict and will
        /// be tried again.
        case offlineRetrying
        case needsSignIn
        case keychainUnreadable

        var live: ICloudLiveSession? {
            switch self {
            case .active(let live), .renewing(let live): return live
            case .paused(let live, _): return live
            default: return nil
            }
        }

        /// Whether a sign-in, a code, or a restore retry is what moves the
        /// session on from here.
        var waitsOnAFlow: Bool {
            switch self {
            case .restoring, .signingIn, .awaitingCode, .renewing, .offlineRetrying: return true
            case .launched, .signedOut, .active, .paused, .needsSignIn, .keychainUnreadable: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .launched
    /// The last failure. Cleared by a session Find My accepts, by starting a
    /// manual sign-in, and by signing out.
    @Published private(set) var lastFailure: ICloudFailure?
    /// The last recorded problem. A diagnostic only: what the session does
    /// next is decided by `phase`.
    @Published private(set) var lastInvalidationReason: InvalidationReason?
    /// When the session last proved itself against Apple: a sign-in, a
    /// restore, or a rotated cookie jar written down. What the menu shows.
    @Published private(set) var lastRenewedAt: Date?
    private static let log = Logger.service("location.icloud.session")

    private let client: ICloudAuthClient
    private let clock: WallClock
    /// Returns once a usable network path exists.
    private let waitForNetwork: @Sendable () async -> Void
    /// Safe cookie validation interval while waiting for Apple account repair
    /// or Find My verification.
    private let recoveryRetryInterval: TimeInterval
    /// A client a launch restore adopted without a Find My probe. The first
    /// of its calls Apple accepts ends the recovery episode, as a probe would.
    private var unprovedClient: ObjectIdentifier?
    /// The wait before each restore retry. Launching at login beats the
    /// Wi-Fi to it, which the network wait covers; a satisfied path is not a
    /// promise that Apple answers, which is what the growing wait is for.
    private static let restoreRetryDelays: [TimeInterval] = [10, 30, 90]

    /// Keychain writes of a rotated jar are spaced at least this far apart.
    /// Apple rotates a cookie on every Find My call, so without spacing each
    /// sample costs one secd write per call. A rotation that lands inside
    /// the window is not dropped: it is written once the window closes.
    private let cookieWriteInterval: TimeInterval
    private var lastCookieWriteAt: Date?
    private var pendingCookieWrite: Task<Void?, Never>?

    /// The one piece of background recovery: a restore retry, a paused poll,
    /// or the renewal after a rejection.
    private var recovery: (id: UUID, kind: RecoveryKind, task: Task<FindMyClient?, Never>)?
    private enum RecoveryKind {
        case restoreRetry
        case pausedPoll
        case renewal
    }

    /// Everything the session has started and not finished, with when it is
    /// due to run, for `settle()`.
    private var running: [UUID: (dueAt: Date, wait: @MainActor () async -> Void)] = [:]
    private var liveClientObservers: [UUID: AsyncStream<FindMyClient?>.Continuation] = [:]

    init(
        transport: ICloudHTTPTransport = ICloudHTTPClient(),
        storage: ICloudCredentialStorage = .production,
        webAuthorizer: FindMyWebAuthorizing,
        cookieWriteInterval: TimeInterval = 60,
        recoveryRetryInterval: TimeInterval = 5 * 60,
        clock: WallClock,
        waitForNetwork: @escaping @Sendable () async -> Void = ICloudSession.waitForUsableNetwork
    ) {
        self.cookieWriteInterval = cookieWriteInterval
        self.recoveryRetryInterval = recoveryRetryInterval
        self.clock = clock
        self.waitForNetwork = waitForNetwork
        self.client = ICloudAuthClient(
            transport: transport,
            storage: storage,
            webAuthorizer: webAuthorizer,
            now: clock.now
        )
    }

    nonisolated static let waitForUsableNetwork: @Sendable () async -> Void = {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        for await path in monitor where path.status == .satisfied {
            return
        }
    }

    // MARK: - What the session says

    var state: State {
        switch phase {
        case .launched, .signedOut: return .signedOut
        case .restoring, .signingIn, .renewing: return .working
        case .awaitingCode(let delivery): return .awaitingCode(delivery)
        case .active(let live): return .signedIn(accountName: live.accountName)
        case .paused(let live?, _): return .signedIn(accountName: live.accountName)
        case .paused(nil, _), .needsSignIn: return .needsReauthentication
        case .offlineRetrying: return .reconnecting
        case .keychainUnreadable: return .credentialsUnreadable
        }
    }

    var failure: String? { lastFailure?.message }

    /// What went wrong, in the one wording the menu, Settings, the Location
    /// window, and the tools all show: the last failure's own words, or the
    /// recorded reason when there is no failure.
    var problem: String? { failure ?? lastInvalidationReason?.description }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var findMy: FindMyClient? { phase.live?.findMy }

    /// Whether Find My can be called now, including while a renewal runs.
    var hasLiveClient: Bool { phase.live != nil }

    var pauseReason: PauseReason? {
        if case .paused(_, let reason) = phase { return reason }
        return nil
    }

    /// Each change of the live Find My client, in order, starting with the
    /// current one.
    func liveClientChanges() -> AsyncStream<FindMyClient?> {
        let (stream, continuation) = AsyncStream<FindMyClient?>.makeStream()
        let id = UUID()
        continuation.yield(findMy)
        liveClientObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.liveClientObservers[id] = nil }
        }
        return stream
    }

    // MARK: - Restore

    func restoreIfNeeded() async {
        guard case .launched = phase else { return }
        await restore(retriesLeft: Self.restoreRetryDelays.count)
    }

    /// Reads the Keychain again after it refused, for the sign-in window's
    /// Try Again.
    func retryKeychain() async {
        guard case .keychainUnreadable = phase else { return }
        await restore(retriesLeft: Self.restoreRetryDelays.count)
    }

    private func restore(retriesLeft: Int, as attempt: Attempt = Attempt()) async {
        transition(to: .restoring(attempt))
        let outcome = await client.recover(.launch)
        guard case .restoring(attempt) = phase else { return }
        land(outcome, after: .restore(retriesLeft: retriesLeft))
    }

    private func scheduleRestoreRetry(retriesLeft: Int) {
        let delay = Self.restoreRetryDelays[Self.restoreRetryDelays.count - retriesLeft - 1]
        scheduleRecovery(.restoreRetry, after: delay) { session, id in
            await session.waitForNetwork()
            guard session.recovery?.id == id, case .offlineRetrying = session.phase else { return nil }
            let attempt = Attempt()
            session.transition(to: .restoring(attempt))
            let outcome = await session.client.recover(.launch)
            guard session.claimRecovery(id), case .restoring(attempt) = session.phase else { return nil }
            return session.land(outcome, after: .restore(retriesLeft: retriesLeft))
        }
    }

    // MARK: - Manual sign-in

    /// Drops the rejected session so the sign-in window asks for credentials.
    /// The stored credentials stay on disk until a new sign-in replaces them.
    func beginManualSignIn() {
        cancelRecovery()
        lastFailure = nil
        transition(to: .needsSignIn)
    }

    func signIn(accountName: String, password: String) async {
        cancelRecovery()
        let attempt = Attempt()
        lastFailure = nil
        lastInvalidationReason = nil
        transition(to: .signingIn(attempt))
        do {
            switch try await client.signIn(accountName: accountName, password: password) {
            case .signedIn(let account):
                guard case .signingIn(attempt) = phase else { return }
                let outcome = await client.verify(account)
                guard case .signingIn(attempt) = phase else { return }
                land(outcome, after: .manualSignIn)
            case .needsTwoFactorCode(let delivery):
                guard case .signingIn(attempt) = phase else { return }
                transition(to: .awaitingCode(delivery))
            }
        } catch {
            await landManualFailure(error, of: attempt, codeStep: nil)
        }
    }

    func submitTwoFactorCode(_ code: String) async {
        guard case .awaitingCode(let delivery) = phase else { return }
        let attempt = Attempt()
        lastFailure = nil
        transition(to: .signingIn(attempt))
        do {
            let account = try await client.submitTwoFactorCode(code)
            guard case .signingIn(attempt) = phase else { return }
            let outcome = await client.verify(account)
            guard case .signingIn(attempt) = phase else { return }
            land(outcome, after: .manualSignIn)
        } catch {
            await landManualFailure(error, of: attempt, codeStep: delivery)
        }
    }

    /// A rejected code returns to the code field: the password was accepted,
    /// and re-entering it would restart the whole flow. A sign-in Apple threw
    /// away returns to the start, where an earlier session may still be on
    /// disk, and calling that signed out would hide it behind a state that
    /// offers no Sign Out.
    private func landManualFailure(
        _ error: Error,
        of attempt: Attempt,
        codeStep delivery: ICloudTwoFactorDelivery?
    ) async {
        let authError = error as? ICloudAuthError
        if authError == .authenticationSuperseded { return }
        if authError == .accountRepairRequired {
            guard case .signingIn(attempt) = phase else { return }
            land(.accountRepairRequired, after: .manualSignIn)
            return
        }
        if let delivery, authError != .sessionExpired {
            guard case .signingIn(attempt) = phase else { return }
            fail(error)
            transition(to: .awaitingCode(delivery))
            return
        }
        let stored = await client.hasStoredSession()
        guard case .signingIn(attempt) = phase else { return }
        fail(error)
        transition(to: stored ? .needsSignIn : .signedOut)
    }

    func signOut() async {
        cancelRecovery()
        pendingCookieWrite?.cancel()
        pendingCookieWrite = nil
        // A sign-out supersedes whatever sign-in, code, or recovery would
        // have moved the session on from here.
        let superseded = phase.waitsOnAFlow ? Attempt() : nil
        if let superseded { transition(to: .restoring(superseded)) }
        do {
            try await client.signOut()
        } catch {
            // The session is still in the Keychain: pick it up again as a
            // relaunch would, unless something newer has taken over. A pause
            // keeps its client and its jar, and only needs its poll back.
            if let superseded, case .restoring(superseded) = phase {
                await restore(retriesLeft: Self.restoreRetryDelays.count, as: superseded)
            } else if case .paused = phase {
                schedulePausedPoll()
            }
            fail(error)
            return
        }
        lastInvalidationReason = nil
        lastFailure = nil
        transition(to: .signedOut)
    }

    // MARK: - Renewal

    /// Waits for the session to renew after Find My rejected `rejected`, and
    /// hands back the renewed client, or nil when it did not renew. The
    /// rejection has already started the renewal, which may even have
    /// finished by the time the caller asks.
    func renewAfterRejection(of rejected: FindMyClient) async -> FindMyClient? {
        if case .active(let live) = phase, live.findMy !== rejected { return live.findMy }
        return await startRenewal()?.value
    }

    private func findMyRejected(_ rejected: ObjectIdentifier) {
        guard case .active(let live) = phase, ObjectIdentifier(live.findMy) == rejected else { return }
        startRenewal()
    }

    /// Single flight: the sampler and a tool call that both see the same 421
    /// share one renewal rather than each costing an email. The renewal runs
    /// in the session's own task, so a caller that goes away, the sampler
    /// cancelling its loop included, cannot cut it short.
    @discardableResult
    private func startRenewal() -> Task<FindMyClient?, Never>? {
        if let recovery, recovery.kind == .renewal { return recovery.task }
        guard case .active = phase else { return nil }
        return scheduleRecovery(.renewal, after: 0) { session, id in
            let outcome = await session.client.recover(
                .findMyRejected,
                willSignIn: { [weak session] in await session?.renewing(during: id) }
            )
            guard session.claimRecovery(id) else { return nil }
            return session.land(outcome, after: .renewal)
        }
    }

    private func renewing(during id: UUID) {
        guard recovery?.id == id, case .active(let live) = phase else { return }
        transition(to: .renewing(live))
    }

    // MARK: - Pause

    private func pause(_ reason: PauseReason, keeping live: ICloudLiveSession?, failure: Error) {
        record(.paused(reason))
        fail(failure)
        transition(to: .paused(live, reason))
        schedulePausedPoll()
    }

    /// Rechecks Apple's cookie session while recovery is paused, and when
    /// Find My still rejects it, may run Find My's own password page once
    /// per episode: `PasswordAttemptGuard` stops a second. It never runs a
    /// full password sign-in. It keeps polling across transient failures
    /// until cookie validation and Find My both accept the session.
    private func schedulePausedPoll() {
        scheduleRecovery(.pausedPoll, after: max(0, recoveryRetryInterval)) { session, id in
            guard case .paused = session.phase else { return nil }
            let outcome = await session.client.recover(.pausedPoll)
            guard session.claimRecovery(id), case .paused = session.phase else { return nil }
            return session.land(outcome, after: .pausedPoll)
        }
    }

    // MARK: - Landing

    private enum Landing: Equatable {
        case restore(retriesLeft: Int)
        case renewal
        case pausedPoll
        case manualSignIn
    }

    /// Every recovery and sign-in ends here, in one switch from what Apple
    /// said to the next phase. Returns the client it adopted, if any.
    @discardableResult
    private func land(_ outcome: ICloudRecoveryOutcome, after landing: Landing) -> FindMyClient? {
        let current = phase.live
        switch outcome {
        case .live(let live):
            adopt(live)
            return live.findMy
        case .renewedRecently:
            lastFailure = .renewedRecently
        case .nothingStored:
            transition(to: .signedOut)
        case .keychainUnreadable:
            // The tokens are still on disk. Looking signed out would open a
            // sign-in sheet that then writes over them.
            record(.credentialsUnreadable)
            fail(ICloudAuthError.credentialsUnreadable)
            transition(to: .keychainUnreadable)
        case .accountRepairRequired:
            pause(.accountRepairRequired, keeping: current, failure: ICloudAuthError.accountRepairRequired)
        case .verificationPending(let error):
            pause(.verificationPending, keeping: current, failure: error)
        case .passwordAttemptSpent:
            pause(
                .repeatedAutomaticSignInStopped,
                keeping: current,
                failure: ICloudAuthError.automaticReauthenticationRecentlyAttempted
            )
        case .needsCode(let delivery, let rejection):
            record(.appleRejectedStoredSession(rejection))
            lastFailure = .codeNeededToRenew
            transition(to: .awaitingCode(delivery))
        case .needsSignIn(let rejection, let error):
            record(.appleRejectedStoredSession(rejection))
            fail(error)
            transition(to: .needsSignIn)
        case .unreachable(let error):
            fail(error)
            switch landing {
            case .restore(let retriesLeft):
                // A network failure is not a signed-out account. Saying so
                // would send the user through a sign-in they do not need.
                record(.restoreFailed(iCloudErrorDetail(error)))
                transition(to: retriesLeft > 0 ? .offlineRetrying : .needsSignIn)
                if retriesLeft > 0 { scheduleRestoreRetry(retriesLeft: retriesLeft - 1) }
            case .pausedPoll:
                schedulePausedPoll()
            case .renewal:
                // A Keychain that refused mid-sign-in leaves the renewal in
                // `renewing`; the old client goes back to work.
                if let current { transition(to: .active(current)) }
            case .manualSignIn:
                break
            }
        case .renewalInterrupted(let error):
            // Not Apple's verdict: the old client stays, so the next call
            // that sees a rejection renews again. Parking in `renewing` would
            // leave nothing to try.
            fail(error)
            transition(to: current.map(Phase.active) ?? .needsSignIn)
        case .superseded:
            break
        }
        return nil
    }

    private func adopt(_ live: ICloudLiveSession) {
        cancelRecovery()
        lastInvalidationReason = nil
        lastFailure = nil
        lastRenewedAt = clock.now()
        let id = ObjectIdentifier(live.findMy)
        unprovedClient = live.acceptedByFindMy ? nil : id
        live.findMy.events.attach(
            didSucceed: { [weak self] in await self?.serviceCallSucceeded(id) },
            onRejected: { [weak self] in await self?.findMyRejected(id) }
        )
        transition(to: .active(live))
    }

    private func transition(to next: Phase) {
        let before = phase.live?.findMy
        phase = next
        let after = next.live?.findMy
        guard before !== after else { return }
        for observer in liveClientObservers.values {
            observer.yield(after)
        }
    }

    private func record(_ reason: InvalidationReason) {
        lastInvalidationReason = reason
        Self.log.error("iCloud recovery issue: \(reason.description, privacy: .public)")
    }

    private func fail(_ error: Error) {
        let failure = ICloudFailure(error)
        if failure == .unreachable {
            Self.log.error(
                "iCloud sign-in failed: \(iCloudErrorDetail(error), privacy: .public) \(error.localizedDescription)"
            )
        }
        lastFailure = failure
    }

    // MARK: - Cookie jar

    /// Called after every Find My call Apple accepted. Compares the live
    /// cookie jar with the Keychain snapshot and writes it when Apple has
    /// rotated anything. Writes are debounced with a trailing edge: a
    /// rotation inside `cookieWriteInterval` of the last write is written
    /// when the window closes, never skipped. (A leading-only throttle here
    /// once left the second of two back-to-back snapshots unpersisted for
    /// 5 min.)
    private func serviceCallSucceeded(_ caller: ObjectIdentifier) async {
        guard isSignedIn, let live = phase.live, ObjectIdentifier(live.findMy) == caller else { return }
        let endsEpisode = unprovedClient == caller
        unprovedClient = nil
        if case .paused = phase {
            cancelRecovery()
            lastInvalidationReason = nil
            lastFailure = nil
            Self.log.notice("Find My recovered without another browser sign-in")
            transition(to: .active(live))
            await writeCookies(endingRecoveryEpisode: true)
            return
        }
        if endsEpisode {
            await writeCookies(endingRecoveryEpisode: true)
            return
        }
        // A trailing write is already queued; it will pick this rotation up.
        if pendingCookieWrite != nil { return }
        if let lastCookieWriteAt {
            let remaining = cookieWriteInterval - clock.now().timeIntervalSince(lastCookieWriteAt)
            if remaining > 0 {
                let write = track(after: remaining) { session -> Void? in
                    session.pendingCookieWrite = nil
                    await session.writeCookies(endingRecoveryEpisode: false)
                    return nil
                }
                pendingCookieWrite = write
                return
            }
        }
        await writeCookies(endingRecoveryEpisode: false)
    }

    /// Best-effort write of the live jar, ignoring the debounce. Called on
    /// quit/terminate so a rotation is not lost to a relaunch.
    func flushCookies() async {
        pendingCookieWrite?.cancel()
        pendingCookieWrite = nil
        await writeCookies(endingRecoveryEpisode: false)
    }

    private func writeCookies(endingRecoveryEpisode: Bool) async {
        guard isSignedIn else { return }
        let didWrite =
            endingRecoveryEpisode
            ? await client.endRecoveryEpisode(disarmingPasswordGuard: true)
            : await client.persistRotatedCookies()
        if didWrite {
            let now = clock.now()
            lastRenewedAt = now
            lastCookieWriteAt = now
        }
    }

    // MARK: - Scheduling

    /// Puts `work` in the one recovery slot, replacing whatever was there.
    /// `work` claims the slot back with `claimRecovery` before it lands, so
    /// whatever it schedules next never cancels the task it runs on.
    @discardableResult
    private func scheduleRecovery(
        _ kind: RecoveryKind,
        after delay: TimeInterval,
        _ work: @escaping @MainActor (ICloudSession, UUID) async -> FindMyClient?
    ) -> Task<FindMyClient?, Never> {
        cancelRecovery()
        let id = UUID()
        let task = track(id: id, after: delay) { session in await work(session, id) }
        recovery = (id, kind, task)
        return task
    }

    private func claimRecovery(_ id: UUID) -> Bool {
        guard recovery?.id == id else { return false }
        recovery = nil
        return true
    }

    private func cancelRecovery() {
        recovery?.task.cancel()
        recovery = nil
    }

    /// Runs `work` on the session after `delay`, recorded for `settle()`
    /// until it finishes.
    private func track<Result: Sendable>(
        id: UUID = UUID(),
        after delay: TimeInterval,
        _ work: @escaping @MainActor (ICloudSession) async -> Result?
    ) -> Task<Result?, Never> {
        let clock = clock
        let dueAt = clock.now().addingTimeInterval(max(0, delay))
        let task = Task { [weak self] () -> Result? in
            defer { self?.running[id] = nil }
            if delay > 0 {
                guard (try? await clock.sleepUntil(dueAt)) != nil else { return nil }
            }
            guard let self, !Task.isCancelled else { return nil }
            return await work(self)
        }
        running[id] = (dueAt, { _ = await task.value })
        return task
    }

    /// Returns once nothing the session started is due: everything that
    /// could run has run, and what remains waits on the clock. Tests move the
    /// clock and call this instead of polling.
    func settle() async {
        while true {
            let now = clock.now()
            let due = running.values.filter { $0.dueAt <= now }.map(\.wait)
            guard !due.isEmpty else { return }
            for wait in due {
                await wait()
            }
        }
    }
}
