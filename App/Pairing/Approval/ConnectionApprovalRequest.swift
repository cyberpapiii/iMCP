import Foundation

enum ApprovalAnswer: Equatable, Sendable {
    case denied
    /// With `pair`, the client's verified key is saved so it is let in
    /// without asking next time. `PairedClientStore.pairingOutcomes` reports
    /// whether that worked.
    case approved(pair: Bool)
}

/// Asks the person at the Mac about one client. Returns `.denied` as soon as
/// the calling task is cancelled, which is how a closed connection withdraws
/// its request.
typealias ApprovalPrompt = @Sendable (ConnectionApprovalRequest) async -> ApprovalAnswer

/// One client asking to connect, as `ServerNetworkManager` puts it to the
/// person at the Mac.
struct ConnectionApprovalRequest: Equatable, Sendable {
    let connectionID: UUID
    /// Already passed through `ServerNetworkManager.sanitizedClientName`.
    let clientName: String
    /// The key the auth preamble verified. Only a verified key can be paired.
    var verifiedFingerprint: String? = nil
}
