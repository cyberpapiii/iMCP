import Foundation

/// What the app logs at each step of a connection's auth preamble. A failed
/// handshake is diagnosed from a user's Console log by grepping these.
enum AuthPreambleDiagnostics {
    static let challengeSent = "auth-preamble challenge sent"
    static let verifiedPaired = "auth-preamble verified-paired"
    static let verifiedUnpaired = "auth-preamble verified-unpaired"
    static let invalidSignature = "auth-preamble invalid-signature"
    static let noResponseGrace = "auth-preamble no-response-grace"
}

/// How long a connection may wait on the person before iMCP gives up on it.
/// Setting up is bounded by `HandshakeDeadline`, which the CLI shares.
enum PhaseDeadline {
    /// How long one request stays on the approval prompt before it is
    /// declined. A session waiting on the prompt is exempt from
    /// `HandshakeDeadline.setup`, because a person can take longer than any
    /// fixed setup time; this is what bounds it instead. The clock starts when the request reaches the
    /// window, so a queued session waits at most this long for each request
    /// ahead of it. `ConnectionApprovalPresenter` enforces it.
    static let approvalPrompt: Duration = .seconds(120)
}

/// What a connection proved with its AUTH-RESPONSE.
enum ConnectionAuth: Equatable {
    case none
    case invalidSignature
    case verifiedUnpaired(fingerprint: String)
    /// Paired already, or it redeemed a pairing code (`byCode`). A code's
    /// pairing is saved only once the connection is admitted: a connection
    /// that is dropped first must not leave a paired key that admits its
    /// next reconnect without asking.
    case preAuthenticated(fingerprint: String, byCode: Bool)
}

enum ConnectionPhase: Equatable {
    case settingUp
    case awaitingApproval
    case approved
    case removing
}

/// One connection's trust and progress, and the rules that follow from them.
/// `ServerNetworkManager` keeps one per accepted socket.
struct ConnectionSession: Equatable {
    enum Admission: Equatable {
        /// In without asking. `pairsByCode` saves the verified key on the way.
        case admit(pairsByCode: Bool)
        case ask
        case deny(DenialReason)
    }

    enum DenialReason: Equatable {
        case invalidSignature
        case approvalQueueFull
    }

    /// Requests an unapproved session may make before it is closed. Serving
    /// rejections forever leaves a client polling on a healthy socket; cut
    /// loose, it reconnects and runs pairing or approval from scratch.
    static let unapprovedRequestLimit = 3

    var auth: ConnectionAuth
    var phase: ConnectionPhase
    private(set) var unapprovedRequests = 0

    init(auth: ConnectionAuth = .none, phase: ConnectionPhase = .settingUp) {
        self.auth = auth
        self.phase = phase
    }

    var verifiedFingerprint: String? {
        switch auth {
        case .verifiedUnpaired(let fingerprint), .preAuthenticated(let fingerprint, _):
            return fingerprint
        case .none, .invalidSignature:
            return nil
        }
    }

    var isApproved: Bool { phase == .approved }

    /// Neither approved nor parked on the person's answer.
    var isStalledSetup: Bool { phase == .settingUp }

    /// The initialize-time decision. A valid signature proves only that the
    /// peer holds a key, which any client can, so an unpaired one is asked
    /// about; a broken or forged handshake is refused without asking.
    func admission(hasRoomToAwaitApproval: Bool) -> Admission {
        switch auth {
        case .preAuthenticated(_, let byCode):
            return .admit(pairsByCode: byCode)
        case .invalidSignature:
            return .deny(.invalidSignature)
        case .none, .verifiedUnpaired:
            return hasRoomToAwaitApproval ? .ask : .deny(.approvalQueueFull)
        }
    }

    mutating func recordUnapprovedRequest() -> Bool {
        unapprovedRequests += 1
        return unapprovedRequests >= Self.unapprovedRequestLimit
    }
}
