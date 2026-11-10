import Foundation
import OSLog
import SRP

/// Apple's endpoints, in one place so a hardcoded host cannot hide in a method.
enum ICloudEndpoint {
    static let idmsa = URL(string: "https://idmsa.apple.com")!
    static let auth = URL(string: "https://idmsa.apple.com/appleauth/auth")!
    static let home = URL(string: "https://www.icloud.com")!
    static let setup = URL(string: "https://setup.icloud.com/setup/ws/1")!

    /// The iCloud web app's own OAuth client. Apple rejects unknown ones.
    static let widgetKey = "d39ba9916b7251055b22c7f910e2ea796ee65e98b2ddecea8f5dde8d9d1a815d"
}

enum ICloudCookie {
    /// The two web-auth cookies the stored record also keeps by value.
    static let webAuthToken = "X-APPLE-WEBAUTH-TOKEN"
    static let webAuthUser = "X-APPLE-WEBAUTH-USER"
    /// Set on a response when Apple gates the account behind updated terms.
    /// It is response-local and is never written to the stored jar.
    static let accountRepair = "X-APPLE-WEBAUTH-REPAIR"
    /// What Find My's own password page sets once it has authorized the session.
    static let findMyAuthorization = "X-APPLE-WEBAUTH-FMIP"
}

/// Apple can email the account owner for every password-bearing sign-in.
/// One unattended attempt is allowed per recovery episode: the guard is armed,
/// and persisted, immediately before the password goes out, and is disarmed
/// only once Find My accepts a session: a probe, or the first accepted call
/// of a session a launch restored. It survives restarts, as the email does,
/// and it has no expiry.
///
/// Find My can reject a session minutes after a password renewal Find My
/// accepted, which has already disarmed the guard; after a reboot it does so
/// to the session a relaunch restored. So arming also stamps
/// `ICloudCredentials.lastUnattendedPasswordAt`, which disarming leaves, and
/// a rejection inside `retryInterval` of it renews nothing.
enum PasswordAttemptGuard {
    static let retryInterval: TimeInterval = 5 * 60

    static func isArmed(_ record: ICloudCredentials) -> Bool {
        record.lastAutomaticReauthenticationAt != nil
    }

    static func password(forUnattendedSignInWith record: ICloudCredentials) throws -> String {
        guard let password = record.password, !password.isEmpty else {
            throw ICloudAuthError.noStoredPassword
        }
        if isArmed(record) {
            throw ICloudAuthError.automaticReauthenticationRecentlyAttempted
        }
        return password
    }

    static func arm(_ record: inout ICloudCredentials, at moment: Date) {
        record.lastAutomaticReauthenticationAt = moment
        record.lastUnattendedPasswordAt = moment
        record.updatedAt = moment
    }

    static func sentRecently(_ record: ICloudCredentials?, now: Date) -> Bool {
        guard let sent = record?.lastUnattendedPasswordAt else { return false }
        return now.timeIntervalSince(sent) < retryInterval
    }

    static func disarm(_ record: inout ICloudCredentials) {
        record.lastAutomaticReauthenticationAt = nil
    }
}

/// The tokens Apple hands back in response headers, accumulated across the
/// steps of a sign-in. Every value here arrives as a header, several of them on
/// 302 responses, which is why the client refuses to follow redirects.
struct ICloudAuthState: Equatable, Sendable {
    var sessionID: String?
    var scnt: String?
    var sessionToken: String?
    var trustToken: String?
    var accountCountry: String?
    var authAttributes: String?

    /// Apple's header-to-field mapping. A step that returns a header not listed
    /// here is a step whose value nothing reads.
    mutating func absorb(_ response: ICloudHTTPResponse) {
        sessionID = response.header("X-Apple-ID-Session-Id") ?? sessionID
        scnt = response.header("scnt") ?? scnt
        sessionToken = response.header("X-Apple-Session-Token") ?? sessionToken
        trustToken = response.header("X-Apple-TwoSV-Trust-Token") ?? trustToken
        accountCountry = response.header("X-Apple-ID-Account-Country") ?? accountCountry
        authAttributes = response.header("X-Apple-Auth-Attributes") ?? authAttributes
    }
}

struct ICloudAccount: Sendable, Equatable {
    let dsid: String
    let webservices: [String: URL]
    /// Apple assigns each account a partition, so the Find My host differs per
    /// account and must never be hardcoded.
    let findMy: URL

    /// An account with web access off authenticates fine and then has no Find
    /// My endpoint, which is the whole reason this service exists, so it is
    /// not an account here.
    init(dsid: String, webservices: [String: URL]) throws {
        guard let findMy = webservices["findme"] else { throw ICloudAuthError.webAccessDisabled }
        self.dsid = dsid
        self.webservices = webservices
        self.findMy = findMy
    }

    init(accountLoginBody body: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ICloudAuthError.unreadableResponse
        }
        guard
            let info = root["dsInfo"] as? [String: Any],
            let dsid = info["dsid"] as? String
        else {
            throw ICloudAuthError.unreadableResponse
        }

        var services: [String: URL] = [:]
        for (key, value) in root["webservices"] as? [String: Any] ?? [:] {
            guard
                let entry = value as? [String: Any],
                let text = entry["url"] as? String,
                let url = URL(string: text),
                AppleDomain.isServiceURL(url)
            else { continue }
            services[key] = url
        }
        try self.init(dsid: dsid, webservices: services)
    }
}

extension ICloudCredentials {
    /// The account a stored session already knows. Nil for credentials written
    /// before endpoints were cached, and nil when Find My is missing, so the
    /// caller falls back to cookie-based validation rather than to a session that
    /// cannot answer the only question this service asks.
    func storedAccount(asOf moment: Date) -> ICloudAccount? {
        guard accountRepairPending != true else { return nil }
        guard let dsid, let webservices, let account = try? ICloudAccount(dsid: dsid, webservices: webservices)
        else { return nil }
        // Endpoints without the jar that authenticates against them are worse
        // than nothing: Apple answers 450 and the user is told to sign in again.
        guard let cookies, !cookies.isEmpty else { return nil }
        // An all-expired jar replays as empty: `restoreCookies` drops
        // `expiresAt <= now`, so counting it live only delays the refresh
        // until the first Find My 450. Session cookies without expiry count.
        let hasLive = cookies.contains { cookie in
            cookie.expiresAt.map { $0 > moment } ?? true
        }
        guard hasLive else { return nil }
        return account
    }
}

/// How Apple will deliver the second factor, so the sign-in window can say
/// where to look rather than just "enter your code".
enum ICloudTwoFactorDelivery: Equatable, Sendable {
    case trustedDevice
    /// The masked number Apple reports, for display only.
    case sms(maskedNumber: String, phoneNumberID: Int)
}

enum ICloudSignInOutcome: Equatable, Sendable {
    case signedIn(ICloudAccount)
    case needsTwoFactorCode(ICloudTwoFactorDelivery)
}

struct ICloudLiveSession: Sendable {
    let findMy: FindMyClient
    let accountName: String
    /// False for a launch restore's cached endpoints, which no Find My call
    /// has tested yet; true once a probe has passed on this client.
    let acceptedByFindMy: Bool
}

/// Why a recovery runs, which decides where on Apple's ladder it starts and
/// how far it may climb.
enum ICloudRecoveryTrigger: Sendable, Equatable {
    case launch
    case findMyRejected
    /// Recovery is paused: no password sign-in may run, only cookie
    /// validation and Find My's own authorization.
    case pausedPoll
}

enum ICloudRecoveryOutcome: Sendable {
    case live(ICloudLiveSession)
    /// The password went out less than `PasswordAttemptGuard.retryInterval`
    /// ago. Nothing was sent; the live client stays.
    case renewedRecently
    case nothingStored
    /// The Keychain refused the read; the tokens may still be there.
    case keychainUnreadable
    /// Apple accepted authentication but gates Find My behind updated terms
    /// or another account action.
    case accountRepairRequired
    /// Authentication completed, but a failure that was not Apple's verdict
    /// kept Find My from confirming it.
    case verificationPending(Error)
    /// The one unattended password sign-in of this recovery episode already ran.
    case passwordAttemptSpent
    /// The trust token lapsed; Apple has sent a code. `rejection` says why
    /// the stored session needed renewing.
    case needsCode(ICloudTwoFactorDelivery, rejection: String)
    /// Nothing automatic can renew the session: no password on file, or Apple
    /// refused it.
    case needsSignIn(rejection: String, Error)
    /// Apple or the network did not answer the cookie check. Nothing changed.
    case unreachable(Error)
    /// The password sign-in failed for a reason Apple did not decide.
    case renewalInterrupted(Error)
    /// Sign-out or a newer sign-in took over.
    case superseded
}

/// An error's own reviewed words, for logs and recorded reasons. Only types
/// marked safe for clients cross this boundary; anything else is reduced to
/// its type, so nothing from Apple's payload enters a record.
func iCloudErrorDetail(_ error: Error) -> String {
    if let facing = error as? ClientFacingError, let description = facing.errorDescription {
        return description
    }
    return errorTypeName(for: error)
}

enum ICloudAuthError: Swift.Error, ClientFacingError, Equatable {
    /// Whether Apple has rejected the stored session outright, so the only
    /// way forward is a fresh sign-in rather than a retry.
    var invalidatesSession: Bool {
        switch self {
        case .trustExpired, .sessionExpired, .noStoredSession, .sessionNotTrusted: return true
        case .appleRejectedRequest(let status): return status == 401 || status == 403
        default: return false
        }
    }

    /// Failures where retrying the silent password sign-in cannot succeed:
    /// bad password, missing password, rejected code. Everything else
    /// (network, 5xx, cancellation, unreadable Keychain) is transient.
    var isPermanentReauthFailure: Bool {
        switch self {
        case .invalidCredentials, .accountNameNotAccepted, .noStoredSession, .noStoredPassword,
            .twoFactorCodeRejected, .webAccessDisabled:
            return true
        default: return false
        }
    }

    case invalidCredentials
    /// Apple would not look up the Apple ID as typed. Nothing was checked
    /// against the password.
    case accountNameNotAccepted
    case twoFactorCodeRejected
    case noStoredSession
    /// The store held a session we could not read. Not the same as signed
    /// out: treating it as missing would invite a new sign-in that overwrites
    /// tokens that are still there.
    case credentialsUnreadable
    case trustExpired
    case webAccessDisabled
    case unreadableResponse
    /// Apple invalidated the sign-in session mid-flow. Recoverable only by
    /// starting over, so it must not read as a rejected code.
    case sessionExpired
    case appleRejectedRequest(status: Int)
    case couldNotStoreSession
    case couldNotClearSession
    /// Apple rejected the stored session and there is no password on file to
    /// sign in again with: the user signed in before passwords were kept.
    case noStoredPassword
    /// `accountLogin` answered 200 but flagged the session as needing a
    /// second-factor challenge. Find My refuses such a session (450), so it
    /// is dead for this app's purposes even though the login succeeded.
    case sessionNotTrusted
    /// Apple accepted the web login but gated iCloud services behind updated
    /// terms or another account-repair step. Another password sign-in cannot
    /// clear that gate.
    case accountRepairRequired
    /// A password sign-in was already attempted recently. This guard survives
    /// app restarts because each successful attempt can trigger an Apple email.
    case automaticReauthenticationRecentlyAttempted
    /// Sign-out or a newer sign-in superseded an in-flight authentication
    /// operation. Late responses must not restore credentials or session state.
    case authenticationSuperseded

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Apple rejected that Apple ID and password."
        case .accountNameNotAccepted:
            return "Apple didn't accept that Apple ID. Enter the email address of your Apple Account."
        case .twoFactorCodeRejected:
            return "Apple rejected that verification code."
        case .noStoredSession:
            return "Not signed in to iCloud. Sign in from the iMCP menu."
        case .credentialsUnreadable:
            return
                "iMCP could not read the stored iCloud session. Unlock the Keychain and try again."
        case .trustExpired:
            return "The iCloud session expired. Sign in again from the iMCP menu."
        case .webAccessDisabled:
            return
                "iCloud did not return a Find My endpoint for this account. "
                + "With Advanced Data Protection on, \"Access iCloud Data on the Web\" "
                + "must be enabled in Settings > Apple Account > iCloud."
        case .unreadableResponse:
            return "iCloud returned a response iMCP could not read."
        case .sessionExpired:
            return "The sign-in session expired before it finished. Start again."
        case .appleRejectedRequest(let status):
            return "iCloud rejected the request (HTTP \(status))."
        case .couldNotStoreSession:
            return "iMCP could not save the iCloud session. Try signing in again."
        case .couldNotClearSession:
            return "iMCP could not remove the iCloud session from the Keychain. Try again."
        case .noStoredPassword:
            return
                "The iCloud session expired and iMCP has no saved password to renew it with. "
                + "Sign in once from the iMCP menu; after that it renews itself."
        case .sessionNotTrusted:
            return
                "iCloud renewed the session but Apple wants a second-factor check before Find My will answer."
        case .accountRepairRequired:
            return
                "Apple requires an account action before Find My can continue. "
                + "Open iCloud.com or Apple Account settings on a trusted device, accept any updated iCloud terms "
                + "or account prompts, then leave iMCP running; it will recover automatically."
        case .automaticReauthenticationRecentlyAttempted:
            return
                "iMCP already tried an automatic iCloud browser sign-in for this recovery. "
                + "It stopped further password sign-ins to prevent repeated Apple emails. "
                + "Open iCloud.com on a trusted device and complete any account prompts; iMCP will keep checking Find My."
        case .authenticationSuperseded:
            return "That iCloud sign-in was cancelled by a newer account action."
        }
    }
}

/// Drives Apple's iCloud web sign-in.
///
/// An actor because the flow is a state machine across several round trips and
/// two of its steps come from the user at unpredictable times: the password,
/// then minutes later the verification code.
///
/// The password is used to derive the SRP proof and is then written to the
/// same data-protection Keychain item as Apple's tokens, so that when Apple
/// throws the session away (which it does, on its own schedule, regardless of
/// cookie expiry) `reauthenticate()` can sign in again without a person. The
/// stored trust token is what lets that sign-in skip the second factor.
actor ICloudAuthClient {
    private let transport: ICloudHTTPTransport
    private let storage: ICloudCredentialStorage
    private let webAuthorizer: FindMyWebAuthorizing
    /// Starts as a fresh id and becomes the stored one as soon as a stored
    /// session is read. See `ICloudCredentials.clientID`.
    private(set) var clientID: String
    /// Set when Find My's page signed in under its own client id: the stored
    /// id is then the wrong one, and the next write replaces it.
    private var clientIDNeedsWrite = false
    private let now: @Sendable () -> Date

    private var state = ICloudAuthState()
    /// The stored record as this actor last read or wrote it, and so the
    /// session its tokens and cookie jar belong to. Nil before the first read,
    /// from the start of a manual sign-in, and after sign-out.
    private var loaded: ICloudCredentials?
    /// The Apple ID a sign-in in progress is for, until its session is saved.
    private var signInAccountName: String?
    /// Held from `signIn` until the session is saved, then dropped. The
    /// Keychain copy is the one that lasts; `reauthenticate()` reads it
    /// from there.
    private var pendingPassword: String?
    private var pendingDelivery: ICloudTwoFactorDelivery?
    /// Actor reentrancy lets sign-out run while a request is awaiting Apple.
    /// Every late response must prove it still belongs to the current flow.
    private var authenticationGeneration: UInt = 0
    private var pendingAuthenticationGeneration: UInt?
    /// What the running recovery does as a password rung begins. Bound per
    /// task, so a recovery's hook is never another's.
    @TaskLocal private static var willSignIn: @Sendable () async -> Void = {}

    init(
        transport: ICloudHTTPTransport,
        storage: ICloudCredentialStorage,
        webAuthorizer: FindMyWebAuthorizing,
        clientID: String = UUID().uuidString.lowercased(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.storage = storage
        self.webAuthorizer = webAuthorizer
        self.clientID = clientID
        self.now = now
    }

    func currentAccountName() -> String? { signInAccountName ?? loaded?.accountName }

    // MARK: - Recovery

    /// Brings the stored session back to one Find My accepts, climbing only
    /// as far up Apple's ladder as it has to: cached endpoints, then cookie
    /// validation, then a Find My probe, then Find My's own password page,
    /// then a full password sign-in. The trigger decides where it starts and
    /// how far it may climb. `willSignIn` runs as either password rung
    /// begins, once a stored password is on file and the one-attempt guard
    /// lets it go out: a full sign-in before its first request, Find My's own
    /// page before the password is armed.
    func recover(
        _ trigger: ICloudRecoveryTrigger,
        willSignIn: @escaping @Sendable () async -> Void = {}
    ) async -> ICloudRecoveryOutcome {
        await Self.$willSignIn.withValue(willSignIn) {
            switch trigger {
            case .launch:
                return await recoverAtLaunch()
            case .findMyRejected:
                if PasswordAttemptGuard.sentRecently(loaded, now: now()) { return .renewedRecently }
                return Self.withoutKeychainVerdict(await recoverAfterRejection())
            case .pausedPoll:
                return Self.withoutKeychainVerdict(await recoverWhilePaused())
            }
        }
    }

    /// A Keychain that refuses a read says nothing about the session. At
    /// launch there is no other session to run on, so it becomes the state;
    /// on every later trigger, whichever rung hit it, the recovery changes
    /// nothing and the next trigger tries again.
    private static func withoutKeychainVerdict(_ outcome: ICloudRecoveryOutcome) -> ICloudRecoveryOutcome {
        guard case .keychainUnreadable = outcome else { return outcome }
        return .unreachable(ICloudAuthError.credentialsUnreadable)
    }

    /// Verifies a manual sign-in against Find My before anyone relies on it.
    func verify(_ account: ICloudAccount) async -> ICloudRecoveryOutcome {
        switch await probe(account, disarmingPasswordGuard: true) {
        case .accepted(let findMy): return .live(live(findMy))
        case .rejected: return .accountRepairRequired
        case .indeterminate(let error): return .verificationPending(error)
        }
    }

    /// Replaying stored endpoints makes a relaunch silent; Find My itself is
    /// the first to test them. Older snapshots without endpoints use Apple's
    /// cookie-based validator, which avoids another password sign-in.
    private func recoverAtLaunch() async -> ICloudRecoveryOutcome {
        let generation = authenticationGeneration
        let account: ICloudAccount
        do {
            let credentials = try await loadStored(generation: generation)
            hydrate(from: credentials)
            if let stored = credentials.storedAccount(asOf: now()) {
                account = stored
            } else {
                account = try await validateAccount(generation: generation)
            }
        } catch ICloudAuthError.noStoredSession {
            return .nothingStored
        } catch ICloudAuthError.credentialsUnreadable {
            return .keychainUnreadable
        } catch let error as ICloudAuthError where error.invalidatesSession {
            // A stale jar replays as cached endpoints, then Apple rejects the
            // validation too. The password path gets first try before the
            // user is asked.
            return await signInAgain(after: iCloudErrorDetail(error))
        } catch {
            return Self.stopped(error) ?? .unreachable(error)
        }
        return .live(
            live(FindMyClient(transport: transport, account: account, clientID: clientID), acceptedByFindMy: false)
        )
    }

    /// Validates the stored browser session and probes Find My with it. Apple
    /// answers 200 to a validation it will not honour for Find My (seen after
    /// a reboot: validate 200, initClient 450), so only the probe counts.
    private func recoverAfterRejection() async -> ICloudRecoveryOutcome {
        let generation = authenticationGeneration
        let account: ICloudAccount
        do {
            hydrate(from: try await loadStored(generation: generation))
            account = try await validateAccount(generation: generation)
        } catch let error as ICloudAuthError where error.invalidatesSession {
            return await signInAgain(after: iCloudErrorDetail(error))
        } catch {
            if let stopped = Self.stopped(error) { return stopped }
            Self.log.error(
                "account validation failed without invalidating the session: \(iCloudErrorDetail(error), privacy: .public)"
            )
            return .unreachable(error)
        }
        switch await probe(account, disarmingPasswordGuard: false) {
        case .accepted(let findMy): return .live(live(findMy))
        case .rejected: return await authorizeFindMyService(after: Self.findMyRejectedRenewal)
        case .indeterminate(let error): return .verificationPending(error)
        }
    }

    /// Paused recovery may only recheck Apple's cookie session and run Find
    /// My's own authorization, which `PasswordAttemptGuard` allows once per
    /// episode; never a full password sign-in. Anything short of an answer
    /// leaves the pause as it was.
    private func recoverWhilePaused() async -> ICloudRecoveryOutcome {
        let generation = authenticationGeneration
        let account: ICloudAccount
        do {
            if loaded == nil {
                hydrate(from: try await loadStored(generation: generation))
            }
            account = try await validateAccount(generation: generation)
        } catch ICloudAuthError.accountRepairRequired {
            return .accountRepairRequired
        } catch ICloudAuthError.authenticationSuperseded {
            return .superseded
        } catch let error as ICloudAuthError where error.invalidatesSession {
            // Apple has dropped the session itself. Nothing on a trusted
            // device brings this one back, and polling it every few minutes
            // would leave the user waiting on a session that is gone.
            return .needsSignIn(rejection: Self.pausedSessionRejected, error)
        } catch {
            return .unreachable(error)
        }
        switch await probe(account, disarmingPasswordGuard: true) {
        case .accepted(let findMy): return .live(live(findMy))
        case .rejected: return await authorizeFindMyService(after: Self.findMyRejectedRenewal)
        case .indeterminate(let error): return .unreachable(error)
        }
    }

    private static let findMyRejectedRenewal = "Find My rejected the renewed session (450)"
    private static let pausedSessionRejected = "Apple rejected the paused session"

    /// Find My has its own password authorization layered over the browser
    /// session. Repair that narrower session first instead of replacing the
    /// entire browser session.
    private func authorizeFindMyService(after rejection: String) async -> ICloudRecoveryOutcome {
        let generation = authenticationGeneration
        let account: ICloudAccount
        let own: PageCandidate
        let candidates: [PageCandidate]
        do {
            let credentials = try await loadStored(generation: generation)
            let password = try PasswordAttemptGuard.password(forUnattendedSignInWith: credentials)
            if state.sessionToken == nil || loaded == nil {
                hydrate(from: credentials)
            }
            await Self.willSignIn()
            try await armPasswordGuard(generation: generation)
            let before = transport.allCookies()
            let authorized = try await webAuthorizer.authorize(
                accountName: credentials.accountName,
                password: password,
                cookies: before
            )
            // A sign-out during the page cleared the jar; the old account's
            // cookies must not land in it.
            try requireCurrent(generation)
            // The endpoints are the stored ones when there are any. Asking
            // the setup service to validate the page's session answered 421
            // on every live run, seconds after Find My had answered the page
            // itself, so validation is not what decides here: Find My is.
            if let stored = credentials.storedAccount(asOf: now()) {
                account = stored
            } else {
                account = try await validateAccount(generation: generation)
            }
            (own, candidates) = pageCandidates(from: authorized, before: before)
        } catch ICloudAuthError.automaticReauthenticationRecentlyAttempted {
            return .passwordAttemptSpent
        } catch FindMyWebAuthorizationError.credentialsRejected {
            // Apple's own page refused the saved password for this narrower
            // challenge. Nothing automatic can fix that; a person has to.
            return .needsSignIn(rejection: rejection, FindMyWebAuthorizationError.credentialsRejected)
        } catch ICloudAuthError.authenticationSuperseded {
            return .superseded
        } catch ICloudAuthError.credentialsUnreadable {
            return .keychainUnreadable
        } catch let error as ICloudAuthError where error.invalidatesSession {
            // The password went out and Apple still refused the session. The
            // one automatic attempt is spent, so waiting cannot help: say so.
            Self.log.error(
                "Apple rejected the session after Find My's page: \(iCloudErrorDetail(error), privacy: .public)"
            )
            return .needsSignIn(rejection: rejection, error)
        } catch {
            Self.log.error("Find My service authorization failed: \(iCloudErrorDetail(error), privacy: .public)")
            return .verificationPending(error)
        }

        var unanswered: Error?
        for candidate in candidates {
            guard generation == authenticationGeneration else { return .superseded }
            install(candidate)
            var answer = await probe(account, disarmingPasswordGuard: true)
            // No answer says nothing about the session, and the page was
            // reaching Apple a moment ago: ask once more before moving on.
            if case .indeterminate = answer {
                answer = await probe(account, disarmingPasswordGuard: true)
            }
            switch answer {
            case .accepted(let findMy):
                Self.log.notice(
                    "Find My accepted \(candidate.name, privacy: .public) after: \(rejection, privacy: .public)"
                )
                return .live(live(findMy))
            case .rejected:
                Self.log.notice("Find My rejected \(candidate.name, privacy: .public)")
            case .indeterminate(let error):
                Self.log.notice(
                    "Find My did not answer for \(candidate.name, privacy: .public): \(iCloudErrorDetail(error), privacy: .public)"
                )
                unanswered = unanswered ?? error
            }
        }
        // Whatever comes next validates the jar in memory, and the setup
        // service answers 421 to the page's: leave iMCP's own session there.
        guard generation == authenticationGeneration else { return .superseded }
        install(own)
        if let unanswered {
            return .verificationPending(unanswered)
        }
        return await rejectedAfterPage(rejection: rejection, generation: generation)
    }

    /// One session to offer Find My after its page: a jar and the client id
    /// it belongs to.
    private struct PageCandidate {
        let name: String
        let cookies: [HTTPCookie]
        let clientID: String
        let clientIDNeedsWrite: Bool
    }

    /// The sessions worth offering, in order, and iMCP's own to fall back on.
    /// iMCP's own browser session goes first, carrying only the service
    /// cookie the page earned: the setup service accepted it moments ago, so
    /// when Find My takes it too the saved session passes the next
    /// validation. The page's whole jar under the page's own client id goes
    /// second; it started from iMCP's cookies, and a superseded token left
    /// beside its replacement would mix two sessions.
    private func pageCandidates(
        from authorized: FindMyWebAuthorization,
        before: [HTTPCookie]
    ) -> (own: PageCandidate, candidates: [PageCandidate]) {
        let service = authorized.cookies.filter { $0.name == ICloudCookie.findMyAuthorization }
        let own = PageCandidate(
            name: service.isEmpty ? "iMCP's own session" : "iMCP's own session with the page's service cookie",
            cookies: before.filter { $0.name != ICloudCookie.findMyAuthorization } + service,
            clientID: clientID,
            clientIDNeedsWrite: clientIDNeedsWrite
        )
        guard !authorized.cookies.isEmpty else { return (own, [own]) }
        // Names only, never values: which cookies the page added and which
        // of iMCP's it dropped is what a failed handover turns on.
        let was = Set(before.map(\.name))
        let now = Set(authorized.cookies.map(\.name))
        Self.log.notice(
            "Find My page jar: \(authorized.cookies.count, privacy: .public) cookies; added \(now.subtracting(was).sorted().joined(separator: ","), privacy: .public); dropped \(was.subtracting(now).sorted().joined(separator: ","), privacy: .public)"
        )
        let pageID = authorized.clientID ?? clientID
        let page = PageCandidate(
            name: "the page's session",
            cookies: authorized.cookies,
            clientID: pageID,
            clientIDNeedsWrite: pageID != clientID || clientIDNeedsWrite
        )
        return (own, service.isEmpty ? [page] : [own, page])
    }

    private func install(_ candidate: PageCandidate) {
        transport.clearCookies()
        transport.install(candidate.cookies)
        clientID = candidate.clientID
        clientIDNeedsWrite = candidate.clientIDNeedsWrite
    }

    /// Apple's page took the password and Find My still refuses every
    /// session. A terms or repair gate is the one case that clears without
    /// a sign-in; anything else needs a person, because the one automatic
    /// password attempt is spent.
    private func rejectedAfterPage(rejection: String, generation: UInt) async -> ICloudRecoveryOutcome {
        do {
            _ = try await validateAccount(generation: generation)
        } catch ICloudAuthError.accountRepairRequired {
            return .accountRepairRequired
        } catch ICloudAuthError.authenticationSuperseded {
            return .superseded
        } catch {
            Self.log.notice(
                "after Find My's page the setup service says: \(iCloudErrorDetail(error), privacy: .public)"
            )
        }
        Self.log.error("Find My rejected every session after its own page accepted the password")
        return .needsSignIn(rejection: rejection, ICloudAuthError.trustExpired)
    }

    /// Signs in again from the stored password without a person. When that
    /// is not enough the outcome says what is: a code, because the trust
    /// token has lapsed, or a full sign-in, because there is no password on
    /// file or Apple refused it.
    private func signInAgain(after rejection: String) async -> ICloudRecoveryOutcome {
        let outcome: ICloudSignInOutcome
        do {
            outcome = try await reauthenticate()
        } catch let error as ICloudAuthError where error.isPermanentReauthFailure {
            Self.log.error("re-sign-in failed permanently: \(iCloudErrorDetail(error), privacy: .public)")
            return .needsSignIn(rejection: rejection, error)
        } catch {
            if let stopped = Self.stopped(error) { return stopped }
            // Network, 5xx, URLError: not Apple's verdict on the session.
            Self.log.error("re-sign-in transient failure: \(iCloudErrorDetail(error), privacy: .public)")
            return .renewalInterrupted(error)
        }
        switch outcome {
        case .signedIn(let account):
            switch await probe(account, disarmingPasswordGuard: true) {
            case .accepted(let findMy):
                Self.log.notice("signed in again without a person after: \(rejection, privacy: .public)")
                return .live(live(findMy))
            case .rejected:
                return .accountRepairRequired
            case .indeterminate(let error):
                return .verificationPending(error)
            }
        case .needsTwoFactorCode(let delivery):
            Self.log.notice("re-sign-in needs a verification code; the trust token has lapsed")
            return .needsCode(delivery, rejection: rejection)
        }
    }

    /// The failures every rung ends on the same way.
    private static func stopped(_ error: Error) -> ICloudRecoveryOutcome? {
        switch error as? ICloudAuthError {
        case .accountRepairRequired: return .accountRepairRequired
        case .credentialsUnreadable: return .keychainUnreadable
        case .automaticReauthenticationRecentlyAttempted: return .passwordAttemptSpent
        case .authenticationSuperseded: return .superseded
        default: return nil
        }
    }

    private enum FindMyProbe {
        case accepted(FindMyClient)
        case rejected
        case indeterminate(Error)
    }

    /// One cached Find My call. Authentication counts only once Apple answers
    /// it; network and server failures stay retryable without another
    /// password sign-in. The client that passed becomes the session's, server
    /// context and all.
    private func probe(_ account: ICloudAccount, disarmingPasswordGuard: Bool) async -> FindMyProbe {
        let findMy = FindMyClient(transport: transport, account: account, clientID: clientID)
        do {
            _ = try await findMy.snapshot(locate: false)
        } catch FindMyError.noDevices {
            // A valid empty account still proves the web session was accepted.
        } catch ICloudAuthError.trustExpired {
            return .rejected
        } catch {
            return .indeterminate(error)
        }
        _ = await endRecoveryEpisode(disarmingPasswordGuard: disarmingPasswordGuard)
        return .accepted(findMy)
    }

    private func live(_ findMy: FindMyClient, acceptedByFindMy: Bool = true) -> ICloudLiveSession {
        ICloudLiveSession(
            findMy: findMy,
            accountName: currentAccountName() ?? "iCloud",
            acceptedByFindMy: acceptedByFindMy
        )
    }

    // MARK: - Ladder rungs

    /// Signs in again from the stored password and trust token. With the
    /// trust token still honored, Apple completes the sign-in without a
    /// second factor and nobody has to touch the Mac; once it lapses (about
    /// 30 days, and only Apple knows exactly), the outcome is
    /// `needsTwoFactorCode` and the code has already been sent to the user's
    /// devices.
    private func reauthenticate() async throws -> ICloudSignInOutcome {
        let generation = beginAuthentication()
        let credentials = try await loadStored(generation: generation)
        let password = try PasswordAttemptGuard.password(forUnattendedSignInWith: credentials)
        loaded = credentials
        adoptClientID(from: credentials)
        await Self.willSignIn()
        do {
            return try await signIn(
                accountName: credentials.accountName,
                password: password,
                trustToken: credentials.trustToken,
                unattended: true,
                generation: generation
            )
        } catch let error where !Self.keepsReplacementSession(error) {
            // Preserve the last stored session after a failed unattended
            // replacement. Direct Find My probes can still recover it.
            try requireCurrent(generation)
            abandonSignIn(restoring: loaded ?? credentials)
            throw error
        }
    }

    /// Ends a sign-in that will not finish: its half-built jar goes, and
    /// `record`, the session it would have replaced, comes back.
    private func abandonSignIn(restoring record: ICloudCredentials?) {
        transport.clearCookies()
        signInAccountName = nil
        pendingPassword = nil
        pendingDelivery = nil
        pendingAuthenticationGeneration = nil
        if let record { hydrate(from: record) }
    }

    /// A repair gate leaves the fresh authenticated jar as the only session
    /// that can recover once the user accepts Apple's terms, and a
    /// superseded attempt has nothing left to restore.
    private static func keepsReplacementSession(_ error: Error) -> Bool {
        switch error as? ICloudAuthError {
        case .accountRepairRequired, .authenticationSuperseded: return true
        default: return false
        }
    }

    // MARK: - Manual sign-in

    /// Whether a session is still on disk. A manual attempt replaces nothing
    /// until it succeeds, so an earlier session and its saved password can
    /// still be there after one fails.
    func hasStoredSession() async -> Bool {
        if case .missing = await storage.load() { return false }
        return true
    }

    func signIn(accountName: String, password: String) async throws -> ICloudSignInOutcome {
        let generation = beginAuthentication()
        loaded = nil
        return try await signIn(
            accountName: accountName,
            password: password,
            trustToken: nil,
            unattended: false,
            generation: generation
        )
    }

    /// An `unattended` sign-in replaces the stored record; its password guard
    /// is armed right before the password-bearing call.
    private func signIn(
        accountName: String,
        password: String,
        trustToken: String?,
        unattended: Bool,
        generation: UInt
    ) async throws -> ICloudSignInOutcome {
        try requireCurrent(generation)
        state = ICloudAuthState()
        state.trustToken = trustToken
        signInAccountName = accountName
        pendingPassword = password
        pendingDelivery = nil
        pendingAuthenticationGeneration = generation
        // A silent reauth must not send the dead jar alongside the fresh SRP
        // flow: stale cookies can earn an immediate 421 for a token that
        // would otherwise succeed.
        transport.clearCookies()

        // Apple sets the initial session cookies on the sign-in shell. Skipping
        // it makes `signin/init` fail in ways that read as a bad password.
        _ = try? await send(authorizeShellRequest(), generation: generation)
        try requireCurrent(generation)

        // One client for the whole exchange: `a` sent on init and the secret
        // that proves `m1` on complete have to be the same ephemeral pair.
        let client = try SRPClient(accountName: accountName)
        let challenge = try await beginSRP(client: client, generation: generation)
        let derived = try SRPClient.derivedPassword(
            password: password,
            salt: challenge.salt,
            iterations: challenge.iteration,
            protocol: challenge.passwordProtocol
        )
        let proof = try client.proof(
            salt: challenge.salt,
            serverPublicKey: challenge.serverPublicKey,
            derivedPassword: derived
        )

        if unattended {
            // Earlier network failures cannot trigger Apple's sign-in email,
            // so they must not consume the recovery episode's one sign-in.
            try await armPasswordGuard(generation: generation)
        }

        let completion = try await completeSRP(
            accountName: accountName,
            challenge: challenge,
            proof: proof,
            clientPublicKey: client.publicKey,
            generation: generation
        )

        switch completion {
        case .signedIn:
            return .signedIn(try await accountLogin(generation: generation))
        case .needsTwoFactorCode:
            let delivery = try await requestTwoFactorCode(generation: generation)
            try requireCurrent(generation)
            pendingDelivery = delivery
            return .needsTwoFactorCode(delivery)
        }
    }

    /// Verifies the code, asks Apple to trust this session, then logs in.
    /// Trusting is what earns the token that keeps the user from doing this
    /// again tomorrow.
    func submitTwoFactorCode(_ code: String) async throws -> ICloudAccount {
        guard let generation = pendingAuthenticationGeneration else {
            throw ICloudAuthError.authenticationSuperseded
        }
        try requireCurrent(generation)
        let response: ICloudHTTPResponse
        switch pendingDelivery ?? .trustedDevice {
        case .trustedDevice:
            response = try await send(
                jsonRequest(
                    .post,
                    ICloudEndpoint.auth.appending(path: "verify/trusteddevice/securitycode"),
                    body: ["securityCode": ["code": code]]
                ),
                generation: generation
            )
        case .sms(_, let phoneNumberID):
            response = try await send(
                jsonRequest(
                    .post,
                    ICloudEndpoint.auth.appending(path: "verify/phone/securitycode"),
                    body: [
                        "phoneNumber": ["id": phoneNumberID],
                        "securityCode": ["code": code],
                        "mode": "sms",
                    ]
                ),
                generation: generation
            )
        }
        guard response.isSuccess else {
            throw ICloudAuthError.twoFactorCodeRejected
        }

        _ = try await send(
            jsonRequest(.get, ICloudEndpoint.auth.appending(path: "2sv/trust")),
            generation: generation
        )
        return try await accountLogin(generation: generation)
    }

    /// Rewrites the stored session with whatever cookies Apple has rotated
    /// since the last write.
    ///
    /// Apple renews the web-auth cookies on ordinary service calls, and only
    /// the in-memory jar sees those renewals. A snapshot frozen at sign-in
    /// time is dead by the time the app relaunches a day or two later, and the
    /// account login that would recover it is rejected for the same reason,
    /// which is how a session that was fine at quit turns into "sign in
    /// again" at launch. No network and no email: this is a Keychain write.
    @discardableResult
    func persistRotatedCookies() async -> Bool {
        await writeLiveJar(endingRecoveryEpisode: false, disarmingPasswordGuard: false)
    }

    /// Find My accepted the session, so the recovery episode is over: the
    /// repair marker goes, and the password guard too when
    /// `disarmingPasswordGuard`. The live jar is written in the same write.
    @discardableResult
    func endRecoveryEpisode(disarmingPasswordGuard: Bool) async -> Bool {
        await writeLiveJar(endingRecoveryEpisode: true, disarmingPasswordGuard: disarmingPasswordGuard)
    }

    /// Refused while a sign-in is in progress: it cleared the jar and is
    /// building a new one, which is no session until it is saved, and a
    /// failed sign-in restores the record this would overwrite.
    private func writeLiveJar(endingRecoveryEpisode: Bool, disarmingPasswordGuard: Bool) async -> Bool {
        guard signInAccountName == nil else { return false }
        let generation = authenticationGeneration
        let current = Self.storedCookies(transport.allCookies())
        let sessionToken = state.sessionToken
        let trustToken = state.trustToken
        let clientID = clientID
        let replacesClientID = clientIDNeedsWrite
        let moment = now()
        let saved: ICloudCredentials?
        do throws(ICloudAuthError) {
            saved = try await storage.update { stored throws(ICloudAuthError) -> ICloudCredentials? in
                guard case .found(let stored) = stored else {
                    throw stored == .missing ? .noStoredSession : .credentialsUnreadable
                }
                let cookiesChanged = !current.isEmpty && Set(stored.cookies ?? []) != Set(current)
                let guardChanged = disarmingPasswordGuard && PasswordAttemptGuard.isArmed(stored)
                let repairChanged = endingRecoveryEpisode && stored.accountRepairPending == true
                let clientIDChanged = replacesClientID && stored.clientID != clientID
                guard cookiesChanged || guardChanged || repairChanged || clientIDChanged else { return nil }

                var updated = stored
                if cookiesChanged { updated.cookies = current }
                if disarmingPasswordGuard { PasswordAttemptGuard.disarm(&updated) }
                if endingRecoveryEpisode { updated.accountRepairPending = false }
                if let sessionToken { updated.sessionToken = sessionToken }
                if let trustToken { updated.trustToken = trustToken }
                if updated.clientID == nil || clientIDChanged { updated.clientID = clientID }
                updated.updatedAt = moment
                return Self.withLegacyWebAuthFields(updated)
            }
        } catch {
            if error == .couldNotStoreSession {
                Self.log.notice(
                    "iCloud session snapshot changed (\(current.count, privacy: .public) cookies); persisted=false"
                )
            }
            return false
        }
        guard generation == authenticationGeneration else { return false }
        if replacesClientID, saved?.clientID == clientID || loaded?.clientID == clientID {
            clientIDNeedsWrite = false
        }
        guard let saved else {
            if disarmingPasswordGuard { loaded?.lastAutomaticReauthenticationAt = nil }
            return false
        }
        loaded = saved
        Self.log.notice("iCloud session snapshot changed (\(current.count, privacy: .public) cookies); persisted=true")
        return true
    }

    private static func storedCookies(_ cookies: [HTTPCookie]) -> [ICloudStoredCookie] {
        cookies.compactMap {
            // This response-local marker can outlive the repaired account in a
            // cookie jar. Persisting it would make every future launch look gated.
            guard $0.name != ICloudCookie.accountRepair else { return nil }
            return ICloudStoredCookie(
                name: $0.name,
                value: $0.value,
                domain: $0.domain,
                path: $0.path,
                expiresAt: $0.expiresDate
            )
        }
    }

    func signOut() async throws {
        let generation = beginAuthentication()
        guard await storage.clear() else {
            // The record is still on disk, and the new generation has
            // superseded any sign-in in progress: nothing else would end it.
            if generation == authenticationGeneration, signInAccountName != nil {
                abandonSignIn(restoring: loaded)
            }
            throw ICloudAuthError.couldNotClearSession
        }
        // A sign-in that started while the Keychain answered owns the state
        // now; its save is queued after this delete.
        guard generation == authenticationGeneration else { return }
        transport.clearCookies()
        state = ICloudAuthState()
        loaded = nil
        signInAccountName = nil
        pendingPassword = nil
        pendingDelivery = nil
        pendingAuthenticationGeneration = nil
    }

    @discardableResult
    private func beginAuthentication() -> UInt {
        authenticationGeneration &+= 1
        return authenticationGeneration
    }

    private func requireCurrent(_ generation: UInt) throws {
        guard generation == authenticationGeneration else {
            throw ICloudAuthError.authenticationSuperseded
        }
    }

    private func loadStored(generation: UInt) async throws -> ICloudCredentials {
        switch await storage.load() {
        case .missing:
            throw ICloudAuthError.noStoredSession
        case .unavailable:
            throw ICloudAuthError.credentialsUnreadable
        case .found(let credentials):
            try requireCurrent(generation)
            return credentials
        }
    }

    // MARK: - SRP

    private struct SRPChallenge {
        let salt: Data
        let serverPublicKey: Data
        let c: String
        let iteration: Int
        let passwordProtocol: SRPPasswordProtocol
    }

    private enum SRPCompletion {
        case signedIn
        case needsTwoFactorCode
    }

    private func beginSRP(client: SRPClient, generation: UInt) async throws -> SRPChallenge {
        let response = try await send(
            jsonRequest(
                .post,
                ICloudEndpoint.auth.appending(path: "signin/init"),
                body: [
                    "a": client.publicKey.base64EncodedString(),
                    "accountName": client.accountName,
                    "protocols": SRPPasswordProtocol.offered,
                ]
            ),
            generation: generation
        )
        guard response.isSuccess else {
            if Self.serviceErrorCodes(in: response.body).contains(Self.accountNameNotAcceptedCode) {
                throw ICloudAuthError.accountNameNotAccepted
            }
            throw Self.rejection(status: response.statusCode)
        }
        guard
            let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            let salt = (body["salt"] as? String).flatMap({ Data(base64Encoded: $0) }), !salt.isEmpty,
            let serverPublicKey = (body["b"] as? String).flatMap({ Data(base64Encoded: $0) }),
            !serverPublicKey.isEmpty,
            let c = body["c"] as? String,
            let iteration = body["iteration"] as? Int,
            let passwordProtocol = (body["protocol"] as? String).flatMap(SRPPasswordProtocol.init(rawValue:))
        else {
            throw ICloudAuthError.unreadableResponse
        }
        return SRPChallenge(
            salt: salt,
            serverPublicKey: serverPublicKey,
            c: c,
            iteration: iteration,
            passwordProtocol: passwordProtocol
        )
    }

    /// Apple's code for an account name it will not look up: an empty one,
    /// or one that is not an Apple Account's email or phone number. Seen on
    /// `signin/init` with HTTP 400, before any password goes out.
    static let accountNameNotAcceptedCode = "-900007"

    static func serviceErrorCodes(in body: Data) -> [String] {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let errors = object["serviceErrors"] as? [[String: Any]]
        else { return [] }
        return errors.compactMap { $0["code"] as? String }
    }

    private func completeSRP(
        accountName: String,
        challenge: SRPChallenge,
        proof: SRPClient.Proof,
        clientPublicKey: Data,
        generation: UInt
    ) async throws -> SRPCompletion {
        var body: [String: Any] = [
            "accountName": accountName,
            "c": challenge.c,
            "m1": proof.m1.base64EncodedString(),
            "m2": proof.m2.base64EncodedString(),
            "rememberMe": true,
            "trustTokens": [],
        ]
        if let trustToken = state.trustToken {
            body["trustTokens"] = [trustToken]
        }

        var url = ICloudEndpoint.auth.appending(path: "signin/complete")
        url.append(queryItems: [URLQueryItem(name: "isRememberMeEnabled", value: "true")])

        let response = try await send(
            jsonRequest(.post, url, body: body),
            generation: generation
        )
        if response.isSuccess { return .signedIn }

        // 409 with `authType: hsa2` is Apple's "now do the second factor".
        guard
            response.statusCode == 409,
            let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            (body["authType"] as? String) == "hsa2"
        else {
            throw Self.rejection(status: response.statusCode)
        }
        return .needsTwoFactorCode
    }

    // MARK: - Two-factor

    /// What Apple says about the current two-factor challenge.
    ///
    /// The shell answers HTML, not JSON: asking for JSON collapses the payload
    /// to an SMS-shaped subset with no trusted-device information in it. The
    /// real state lives in a `boot_args` script block on the page.
    struct TwoFactorOptions {
        /// Apple's own name for the route it wants, e.g. `auth/bridge/step`.
        /// Logged rather than acted on: a route iMCP does not implement has to
        /// be visible in the logs instead of failing as a rejected code.
        let route: String?
        let hasTrustedDevices: Bool
        let phone: (id: Int, masked: String)?
        let fields: [String]

        init(body: Data) {
            var root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if root == nil, let html = String(data: body, encoding: .utf8) {
                root = Self.bootArguments(in: html)
            }
            let top = root ?? [:]
            let direct = top["direct"] as? [String: Any] ?? [:]
            let merged = direct.merging(top) { current, _ in current }

            self.fields = merged.keys.sorted()
            self.route = merged["authInitialRoute"] as? String
            let devices = merged["trustedDevices"] as? [[String: Any]] ?? []
            self.hasTrustedDevices = !devices.isEmpty || merged["hasTrustedDevices"] as? Bool == true
            self.phone = Self.trustedPhoneNumber(in: merged)
        }

        /// The page embeds its state as JSON in a `boot_args` script tag.
        private static func bootArguments(in html: String) -> [String: Any]? {
            guard let marker = html.range(of: "boot_args") else { return nil }
            guard let open = html.range(of: ">", range: marker.upperBound ..< html.endIndex),
                let close = html.range(of: "</script>", range: open.upperBound ..< html.endIndex)
            else { return nil }
            let json = String(html[open.upperBound ..< close.lowerBound])
            return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        }

        private static func trustedPhoneNumber(in body: [String: Any]) -> (
            id: Int, masked: String
        )? {
            var candidates: [[String: Any]] = []
            if let single = body["trustedPhoneNumber"] as? [String: Any] {
                candidates.append(single)
            }
            candidates.append(contentsOf: body["trustedPhoneNumbers"] as? [[String: Any]] ?? [])
            if let verification = body["phoneNumberVerification"] as? [String: Any] {
                if let single = verification["trustedPhoneNumber"] as? [String: Any] {
                    candidates.append(single)
                }
                candidates.append(
                    contentsOf: verification["trustedPhoneNumbers"] as? [[String: Any]] ?? []
                )
            }
            for entry in candidates {
                guard let id = entry["id"] as? Int else { continue }
                let masked =
                    entry["numberWithDialCode"] as? String
                    ?? entry["obfuscatedNumber"] as? String
                    ?? "your phone"
                return (id, masked)
            }
            return nil
        }
    }

    private func fetchTwoFactorOptions(generation: UInt) async throws -> TwoFactorOptions {
        var request = try jsonRequest(.get, ICloudEndpoint.auth)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let options = TwoFactorOptions(body: try await send(request, generation: generation).body)
        Self.log.notice(
            """
            two-factor challenge: route=\(options.route ?? "none", privacy: .public)             trustedDevices=\(options.hasTrustedDevices, privacy: .public)             phone=\(options.phone != nil, privacy: .public)             fields=\(options.fields.joined(separator: ","), privacy: .public)
            """
        )
        return options
    }

    /// Apple does not push a code on its own for a non-browser session, so this
    /// asks for one. Trusted devices first; a phone number is the fallback for
    /// an account with no other Apple device to hand.
    private func requestTwoFactorCode(generation: UInt) async throws -> ICloudTwoFactorDelivery {
        let options = try await fetchTwoFactorOptions(generation: generation)

        let push = try await send(
            jsonRequest(.get, ICloudEndpoint.auth.appending(path: "verify/trusteddevice")),
            generation: generation
        )
        if push.isSuccess { return .trustedDevice }

        guard let phone = options.phone else {
            // The push request failing does not mean no code arrived, so ask
            // for the code rather than declaring a failure the user cannot act
            // on. The logged status above says what actually happened.
            return .trustedDevice
        }

        _ = try await send(
            jsonRequest(
                .put,
                ICloudEndpoint.auth.appending(path: "verify/phone"),
                body: ["phoneNumber": ["id": phone.id], "mode": "sms"]
            ),
            generation: generation
        )
        return .sms(maskedNumber: phone.masked, phoneNumberID: phone.id)
    }

    // MARK: - Account login

    /// The two setup calls that prove a session and return its endpoints.
    private enum AccountCheck: String {
        case validate
        case accountLogin

        /// Behind a repair gate, `accountLogin` still describes the account's
        /// endpoints; `validate`'s body is not trusted for them.
        var keepsEndpointsWhileGated: Bool { self == .accountLogin }
    }

    /// Checks the saved browser session without resubmitting the password.
    /// Current iCloud clients use this route to reuse saved cookies without a
    /// new password sign-in or its account notification.
    private func validateAccount(generation: UInt) async throws -> ICloudAccount {
        let url = ICloudWebRequest.url(
            ICloudEndpoint.setup,
            path: "validate",
            version: await transport.iCloudWebClientVersion(forceRefresh: false),
            clientID: clientID,
            extra: [URLQueryItem(name: "requestId", value: UUID().uuidString)]
        )
        let response = try await send(
            ICloudWebRequest.postNull(url),
            generation: generation
        )
        guard response.isSuccess else {
            throw ICloudAuthError.appleRejectedRequest(status: response.statusCode)
        }
        return try await account(from: response, check: .validate, generation: generation)
    }

    /// Exchanges the session token for the account's service endpoints, then
    /// persists what a later launch needs.
    private func accountLogin(generation: UInt) async throws -> ICloudAccount {
        guard let sessionToken = state.sessionToken else {
            throw ICloudAuthError.noStoredSession
        }

        let url = ICloudWebRequest.url(
            ICloudEndpoint.setup,
            path: "accountLogin",
            version: await transport.iCloudWebClientVersion(forceRefresh: false),
            clientID: clientID
        )

        let response = try await send(
            ICloudWebRequest.post(
                url,
                body: [
                    "accountCountryCode": state.accountCountry ?? "",
                    "dsWebAuthToken": sessionToken,
                    "extended_login": true,
                    "trustToken": state.trustToken ?? "",
                ]
            ),
            generation: generation
        )
        guard response.isSuccess else {
            // Which of the three inputs was missing is the difference between a
            // stale token and a step that never returned one, and the status
            // alone cannot tell them apart.
            Self.log.notice(
                """
                accountLogin rejected: country=\(self.state.accountCountry ?? "none", privacy: .public) \
                trustToken=\(self.state.trustToken != nil, privacy: .public)
                """
            )
            throw ICloudAuthError.appleRejectedRequest(status: response.statusCode)
        }

        return try await account(from: response, check: .accountLogin, generation: generation)
    }

    private func account(
        from response: ICloudHTTPResponse,
        check: AccountCheck,
        generation: UInt
    ) async throws -> ICloudAccount {
        try requireCurrent(generation)
        guard let sessionToken = state.sessionToken else {
            throw ICloudAuthError.noStoredSession
        }
        let flags = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
        let dsInfo = flags["dsInfo"] as? [String: Any]
        let termsUpdateNeeded =
            flags["termsUpdateNeeded"] as? Bool == true
            || dsInfo?["termsUpdateNeeded"] as? Bool == true
        let cookies = transport.allCookies()
        // Read the marker from this response, not the accumulated jar. Apple's
        // old marker can outlive the repair and must not pin recovery forever.
        let repairCookie =
            response.header("Set-Cookie")?.localizedCaseInsensitiveContains(ICloudCookie.accountRepair) == true
        if termsUpdateNeeded || repairCookie {
            Self.log.error(
                "\(check.rawValue, privacy: .public) requires account repair: terms=\(termsUpdateNeeded, privacy: .public) repairCookie=\(repairCookie, privacy: .public)"
            )
            // Keeping the authenticated replacement session while Apple waits
            // for terms is what lets it recover without another email-producing
            // password sign-in.
            try await persist(
                sessionToken: sessionToken,
                account: check.keepsEndpointsWhileGated ? try? ICloudAccount(accountLoginBody: response.body) : nil,
                cookies: cookies,
                accountRepairPending: true,
                generation: generation
            )
            throw ICloudAuthError.accountRepairRequired
        }

        let account = try ICloudAccount(accountLoginBody: response.body)
        // A 200 is not a usable session. Apple flags one that still owes a
        // second factor, and Find My answers 450 to it. Logged either way so a
        // renewal that Find My then rejects can be read back from the log.
        let challengeRequired = flags["hsaChallengeRequired"] as? Bool
        let trustedBrowser = flags["hsaTrustedBrowser"] as? Bool
        Self.log.notice(
            """
            \(check.rawValue, privacy: .public) accepted: hsaChallengeRequired=\(challengeRequired.map(String.init) ?? "absent", privacy: .public) \
            hsaTrustedBrowser=\(trustedBrowser.map(String.init) ?? "absent", privacy: .public)
            """
        )
        if challengeRequired == true {
            throw ICloudAuthError.sessionNotTrusted
        }

        try await persist(
            sessionToken: sessionToken,
            account: account,
            cookies: cookies,
            accountRepairPending: false,
            generation: generation
        )
        return account
    }

    // MARK: - The stored record

    /// The legacy web-auth value fields, kept in step with the jar for a
    /// downgrade to read. Every record written goes through here.
    private static func withLegacyWebAuthFields(_ record: ICloudCredentials) -> ICloudCredentials {
        var record = record
        record.webAuthToken =
            record.cookies?.first { $0.name == ICloudCookie.webAuthToken }?.value ?? record.webAuthToken
        record.webAuthUser = record.cookies?.first { $0.name == ICloudCookie.webAuthUser }?.value ?? record.webAuthUser
        return record
    }

    /// Arms the guard on the stored record, immediately before the
    /// password-bearing call it guards. Every unattended password goes out
    /// through here, Find My's own page and a full sign-in alike. The record
    /// is read and saved in one Keychain call, and a record another rung
    /// armed meanwhile sends nothing.
    private func armPasswordGuard(generation: UInt) async throws {
        try requireCurrent(generation)
        let moment = now()
        let armed = try await storage.update { stored throws(ICloudAuthError) -> ICloudCredentials? in
            guard case .found(var record) = stored else {
                throw stored == .missing ? .noStoredSession : .credentialsUnreadable
            }
            if PasswordAttemptGuard.isArmed(record) { throw .automaticReauthenticationRecentlyAttempted }
            PasswordAttemptGuard.arm(&record, at: moment)
            return Self.withLegacyWebAuthFields(record)
        }
        try requireCurrent(generation)
        loaded = armed
    }

    /// Saves the session an account login or validation just proved. With an
    /// account, the record is rebuilt from this session; without one (a
    /// repair gate that named no endpoints), the stored record is updated in
    /// place so its endpoints survive. The record it replaces is read and the
    /// new one saved in one Keychain call, so no other write lands between.
    private func persist(
        sessionToken: String,
        account: ICloudAccount?,
        cookies: [HTTPCookie],
        accountRepairPending: Bool,
        generation: UInt
    ) async throws {
        try requireCurrent(generation)
        if account != nil, currentAccountName() == nil { return }
        let jar = Self.storedCookies(cookies)
        let accountName = currentAccountName()
        let authState = state
        let password = pendingPassword
        let clientID = clientID
        let loadedGuard = loaded?.lastAutomaticReauthenticationAt
        let loadedPasswordSentAt = loaded?.lastUnattendedPasswordAt
        let moment = now()
        let saved = try await storage.update { stored throws(ICloudAuthError) -> ICloudCredentials? in
            let previous: ICloudCredentials?
            switch stored {
            case .found(let existing): previous = existing
            case .missing: previous = nil
            case .unavailable:
                // With a password in hand the write is complete without the
                // stored copy. Without one it is the only copy, and writing
                // blind would erase it.
                if password == nil { throw ICloudAuthError.credentialsUnreadable }
                previous = nil
            }
            var record: ICloudCredentials
            if let account {
                guard let accountName else { return nil }
                // `trustedAt` marks the trust token's birth, not the last refresh. It
                // is diagnostic only; Apple, not a local age guess, decides
                // validity. A new trust token (a fresh 2FA sign-in, or Apple
                // rotating it) is a new birth.
                let previousTrustedAt = previous.flatMap { $0.trustToken == authState.trustToken ? $0.trustedAt : nil }
                record = ICloudCredentials(
                    accountName: accountName,
                    accountCountry: authState.accountCountry ?? "",
                    sessionToken: sessionToken,
                    trustToken: authState.trustToken,
                    webAuthToken: nil,
                    webAuthUser: nil,
                    trustedAt: previousTrustedAt ?? moment,
                    dsid: account.dsid,
                    webservices: account.webservices,
                    cookies: jar,
                    password: password ?? previous?.password,
                    clientID: clientID,
                    lastAutomaticReauthenticationAt: previous?.lastAutomaticReauthenticationAt ?? loadedGuard,
                    lastUnattendedPasswordAt: previous?.lastUnattendedPasswordAt ?? loadedPasswordSentAt
                )
            } else {
                guard let accountName = accountName ?? previous?.accountName else { return nil }
                record =
                    previous
                    ?? ICloudCredentials(
                        accountName: accountName,
                        accountCountry: authState.accountCountry ?? "",
                        sessionToken: sessionToken,
                        trustToken: authState.trustToken,
                        webAuthToken: nil,
                        webAuthUser: nil,
                        trustedAt: moment
                    )
                record.accountName = accountName
                record.accountCountry = authState.accountCountry ?? record.accountCountry
                record.sessionToken = sessionToken
                record.trustToken = authState.trustToken ?? record.trustToken
                if !jar.isEmpty { record.cookies = jar }
                record.password = password ?? record.password
                record.clientID = clientID
                record.lastAutomaticReauthenticationAt = record.lastAutomaticReauthenticationAt ?? loadedGuard
                record.lastUnattendedPasswordAt = record.lastUnattendedPasswordAt ?? loadedPasswordSentAt
            }
            record.updatedAt = moment
            record.accountRepairPending = accountRepairPending
            return Self.withLegacyWebAuthFields(record)
        }
        guard let saved else { return }
        // Sign-out or a new sign-in ran while the Keychain answered; the
        // actor's state is theirs now.
        try requireCurrent(generation)
        loaded = saved
        signInAccountName = nil
        pendingPassword = nil
    }

    /// Credentials written before the id was stored keep this process's id,
    /// which the next persist writes down; from then on it is stable.
    private func adoptClientID(from credentials: ICloudCredentials) {
        if let stored = credentials.clientID, !stored.isEmpty {
            clientID = stored
        }
    }

    private func hydrate(from credentials: ICloudCredentials) {
        adoptClientID(from: credentials)
        restoreCookies(from: credentials)
        state.sessionToken = credentials.sessionToken
        state.trustToken = credentials.trustToken
        state.accountCountry = credentials.accountCountry
        loaded = credentials
    }

    private func restoreCookies(from credentials: ICloudCredentials) {
        var cookies: [HTTPCookie] = []
        let moment = now()
        for stored in credentials.cookies ?? [] {
            // An expired cookie is not worth replaying, and sending one can make
            // Apple reject the whole jar rather than just ignore that entry.
            if let expiresAt = stored.expiresAt, expiresAt <= moment { continue }
            // Every cookie Apple sets here is Secure, and the stored form
            // does not record the flag. Without it a restored cookie
            // could be sent over plain HTTP.
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: stored.name,
                .value: stored.value,
                .domain: stored.domain,
                .path: stored.path,
                .secure: "TRUE",
            ]
            properties[.expires] = stored.expiresAt
            guard let cookie = HTTPCookie(properties: properties) else { continue }
            cookies.append(cookie)
        }

        if cookies.isEmpty {
            // Credentials written before the whole jar was kept. Enough to
            // validate the saved session, which writes the full jar next time.
            for (name, value) in [
                (ICloudCookie.webAuthToken, credentials.webAuthToken),
                (ICloudCookie.webAuthUser, credentials.webAuthUser),
            ] {
                guard let value else { continue }
                guard
                    let cookie = HTTPCookie(properties: [
                        .name: name,
                        .value: value,
                        .domain: ".icloud.com",
                        .path: "/",
                        .secure: "TRUE",
                    ])
                else { continue }
                cookies.append(cookie)
            }
        }

        transport.install(cookies)
    }

    // MARK: - Requests

    private enum Method: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
    }

    /// Every step's method, path, and status. No tokens, no codes, no
    /// password: a failed sign-in is otherwise indistinguishable from a wrong
    /// password, and there is no second chance to observe one — repeated
    /// attempts lock the Apple ID.
    private static let log = Logger.service("location.icloud")

    private func send(
        _ request: URLRequest,
        generation: UInt
    ) async throws -> ICloudHTTPResponse {
        try requireCurrent(generation)
        let response = try await transport.send(request)
        try requireCurrent(generation)
        state.absorb(response)
        Self.log.notice(
            "\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.path ?? "", privacy: .public) -> \(response.statusCode, privacy: .public) [\(Self.tokenHeadersPresent(in: response), privacy: .public)]"
        )
        // Both of Apple's session statuses mean start over here, not "try
        // another code".
        if AppleSessionStatus(statusCode: response.statusCode) != nil {
            // Apple's own one-line reason ("Missing X-APPLE-WEBAUTH-TOKEN
            // cookie" and the like) is the only thing that tells one dead
            // session from another. Only its known words are logged.
            if let reason = Self.rejectionReason(in: response.body) {
                Self.log.notice("Apple's reason: \(reason, privacy: .public)")
            }
            throw ICloudAuthError.sessionExpired
        }
        return response
    }

    /// The `error` or `reason` string of a rejection body, for a log line
    /// anyone can read. The text is Apple's, so nothing in it is trusted:
    /// a word survives only when it is on the short list below or is one of
    /// the cookie names this client already names. Every other word, plain
    /// letters included, becomes a mark.
    static func rejectionReason(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let text = (object["error"] as? String) ?? (object["reason"] as? String)
        else { return nil }
        var words: [String] = []
        for piece in text.components(separatedBy: rejectionSeparators) where !piece.isEmpty {
            let word = piece.trimmingCharacters(in: .punctuationCharacters)
            let known = rejectionWords.contains(word.lowercased()) || rejectionNames.contains(word.uppercased())
            if known {
                words.append(word)
            } else if words.last != rejectionMark {
                words.append(rejectionMark)
            }
        }
        return String(words.joined(separator: " ").prefix(120))
    }

    private static let rejectionMark = "…"
    private static let rejectionSeparators = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "=:;,\"'")
    )
    private static let rejectionNames: Set<String> = [
        ICloudCookie.webAuthToken, ICloudCookie.webAuthUser, ICloudCookie.accountRepair,
        ICloudCookie.findMyAuthorization,
    ]
    /// Grown only from reasons seen in logs.
    private static let rejectionWords: Set<String> = [
        "a", "an", "and", "authentication", "authorization", "cookie", "cookies", "expired", "for", "found",
        "header", "invalid", "is", "missing", "no", "not", "or", "request", "required", "session", "the", "token",
        "unauthorized",
    ]

    /// Which tokens a step handed back, by name only. A step that returns no
    /// session token is the difference between a stale token and one that was
    /// never issued, and the status code cannot tell them apart.
    private static func tokenHeadersPresent(in response: ICloudHTTPResponse) -> String {
        let names = [
            "X-Apple-Session-Token": "session",
            "X-Apple-TwoSV-Trust-Token": "trust",
            "X-Apple-ID-Account-Country": "country",
            "X-Apple-ID-Session-Id": "sessionId",
        ]
        return names.keys.sorted()
            .compactMap { response.header($0) != nil ? names[$0] : nil }
            .joined(separator: ",")
    }

    /// 401 is how Apple answers a wrong Apple ID or password. Every other
    /// status (throttling, an outage, a changed protocol) says nothing
    /// about the credentials, and calling it a wrong password would end a
    /// session the stored password could still renew.
    private static func rejection(status: Int) -> ICloudAuthError {
        status == 401 ? .invalidCredentials : .appleRejectedRequest(status: status)
    }

    private func jsonRequest(
        _ method: Method,
        _ url: URL,
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        for (name, value) in authHeaders() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func authorizeShellRequest() throws -> URLRequest {
        var url = ICloudEndpoint.auth.appending(path: "authorize/signin")
        url.append(queryItems: [
            URLQueryItem(name: "frame_id", value: clientID),
            URLQueryItem(name: "skVersion", value: "7"),
            URLQueryItem(name: "iframeid", value: clientID),
            URLQueryItem(name: "client_id", value: ICloudEndpoint.widgetKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: ICloudEndpoint.home.absoluteString),
            URLQueryItem(name: "response_mode", value: "web_message"),
            URLQueryItem(name: "state", value: clientID),
            URLQueryItem(name: "authVersion", value: "latest"),
        ])
        return try jsonRequest(.get, url)
    }

    /// `scnt` and the session id are echoed on every step after the first.
    /// Apple drops the flow without them.
    private func authHeaders() -> [String: String] {
        var headers: [String: String] = [
            "Accept": "application/json, text/javascript",
            "Content-Type": "application/json",
            "Referer": ICloudEndpoint.idmsa.absoluteString,
            "X-Apple-FD-Client-Info": Self.clientInfo,
            "X-Apple-OAuth-Client-Id": ICloudEndpoint.widgetKey,
            "X-Apple-OAuth-Client-Type": "firstPartyAuth",
            "X-Apple-OAuth-Redirect-URI": ICloudEndpoint.home.absoluteString,
            "X-Apple-OAuth-Require-Grant-Code": "true",
            "X-Apple-OAuth-Response-Mode": "web_message",
            "X-Apple-OAuth-Response-Type": "code",
            "X-Apple-OAuth-State": clientID,
            "X-Apple-Frame-Id": clientID,
            "X-Apple-Widget-Key": ICloudEndpoint.widgetKey,
        ]
        if let scnt = state.scnt { headers["scnt"] = scnt }
        if let sessionID = state.sessionID { headers["X-Apple-ID-Session-Id"] = sessionID }
        if let attributes = state.authAttributes {
            headers["X-Apple-Auth-Attributes"] = attributes
        }
        return headers
    }

    /// The browser fingerprint Apple's identity service expects alongside the
    /// OAuth headers.
    private static let clientInfo = """
        {"U":"\(ICloudHTTPClient.userAgent)","L":"en-US","Z":"GMT+00:00","V":"1.1","F":""}
        """

}
