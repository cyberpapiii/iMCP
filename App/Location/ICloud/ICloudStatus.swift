import Foundation

enum ICloudStatus {
    /// Everything the menu and Settings say about the session, worked out
    /// from one snapshot of it.
    struct Report: Equatable {
        var summary: StatusSummary
        /// Whether the session stays unusable until the owner acts. Settings
        /// orders and labels its row by this, and the menu lists every such
        /// row.
        var needsOwner: Bool
        var isSignedIn: Bool
        /// Signed in, but Find My waits for a person: Settings offers a fresh
        /// sign-in beside Sign Out.
        var offersSignInAgain: Bool
        var isWorking: Bool
        var destination: StatusDestination
        /// The last thing that went wrong, for Settings.
        var note: String?
    }

    /// `problem` is `ICloudSession.problem`, the wording every surface shares.
    static func report(
        state: ICloudSession.State,
        lastRenewedAt: Date?,
        pauseReason: ICloudSession.PauseReason? = nil,
        problem: String? = nil,
        now: Date = Date()
    ) -> Report {
        let isSignedIn: Bool
        if case .signedIn = state { isSignedIn = true } else { isSignedIn = false }
        return Report(
            summary: summary(state: state, lastRenewedAt: lastRenewedAt, pauseReason: pauseReason, now: now),
            needsOwner: needsOwner(state: state, pauseReason: pauseReason),
            isSignedIn: isSignedIn,
            offersSignInAgain: isSignedIn && pauseReason != nil,
            isWorking: state == .working,
            // A paused recovery is not fixed by the sign-in form, so it leads
            // to Settings, where the account's details are.
            destination: isSignedIn || pauseReason != nil ? .settings : .iCloudSignIn,
            note: problem.map { "Last problem: \($0)" }
        )
    }

    @MainActor
    static func report(of session: ICloudSession, now: Date = Date()) -> Report {
        report(
            state: session.state,
            lastRenewedAt: session.lastRenewedAt,
            pauseReason: session.pauseReason,
            problem: session.problem,
            now: now
        )
    }

    /// What every tool throws when Find My cannot be called, for any
    /// reason: the menu's words and the session's problem.
    @MainActor
    static func toolError(of session: ICloudSession) -> FindMyError {
        let problem = session.problem
        if session.state == .signedOut, problem == nil { return .notSignedIn }
        return .sessionUnavailable(status: toolStatus(of: session), problem: problem)
    }

    /// The menu's words, except where the menu reads signed in although Find
    /// My refused the live client and the renewal that started brought no
    /// new one. A paused session says why it is paused, as the menu does.
    @MainActor
    private static func toolStatus(of session: ICloudSession) -> String {
        guard session.hasLiveClient, session.pauseReason == nil else {
            return summary(state: session.state, lastRenewedAt: nil, pauseReason: session.pauseReason).detail
        }
        if session.lastFailure == .renewedRecently { return "renewed minutes ago · renewing again automatically" }
        return "the renewal did not finish"
    }

    /// The one answer to "does the iCloud row need the owner". A paused
    /// recovery waits for a person even while it keeps polling, and a code
    /// waits for the owner to type it.
    static func needsOwner(state: ICloudSession.State, pauseReason: ICloudSession.PauseReason?) -> Bool {
        guard pauseReason == nil else { return true }
        switch state {
        case .signedIn, .working, .reconnecting: return false
        case .awaitingCode, .needsReauthentication, .credentialsUnreadable, .signedOut: return true
        }
    }

    /// What the menu says about the iCloud session. `lastRenewedAt` is when
    /// the session last proved itself against Apple (a sign-in, a restore, or
    /// a rotated cookie jar written down), which is the fact a user who has
    /// been signed out too many times wants to see.
    static func summary(
        state: ICloudSession.State,
        lastRenewedAt: Date?,
        pauseReason: ICloudSession.PauseReason? = nil,
        now: Date = Date()
    ) -> StatusSummary {
        switch pauseReason {
        case .accountRepairRequired:
            return StatusSummary(
                level: .problem,
                title: "iCloud",
                detail: "Account action required"
            )
        case .verificationPending:
            return StatusSummary(
                level: .attention,
                title: "iCloud",
                detail: "Verifying Find My · retrying automatically"
            )
        case .repeatedAutomaticSignInStopped:
            return StatusSummary(
                level: .problem,
                title: "iCloud",
                detail: "Automatic sign-in paused"
            )
        case nil:
            break
        }

        switch state {
        case .signedIn(let accountName):
            let renewed = lastRenewedAt.map { "renewed \(RelativeAge.text(since: $0, now: now))" } ?? "signed in"
            return StatusSummary(level: .ok, title: "iCloud", detail: "\(accountName) · \(renewed)")
        case .working:
            return StatusSummary(level: .attention, title: "iCloud", detail: working)
        case .reconnecting:
            return StatusSummary(level: .attention, title: "iCloud", detail: reconnecting)
        case .awaitingCode:
            return StatusSummary(level: .attention, title: "iCloud", detail: awaitingCode)
        case .needsReauthentication:
            return StatusSummary(level: .problem, title: "iCloud", detail: signIn)
        case .credentialsUnreadable:
            return StatusSummary(
                level: .problem,
                title: "iCloud",
                detail: "\(unreadable). \(unlockKeychain)"
            )
        case .signedOut:
            return StatusSummary(level: .problem, title: "iCloud", detail: "Not signed in to iCloud")
        }
    }

    // The one set of words for the session's states. The menu, Settings, the
    // Location window and the sign-in window all take them from here.
    static let signIn = "Sign in to iCloud"
    static let working = "Signing in…"
    static let reconnecting = "Reconnecting · retrying automatically"
    static let awaitingCode = "Enter your verification code"
    static let unreadable = "Can't read your saved sign-in"
    static let unlockKeychain = "Unlock your Mac's keychain"
}
