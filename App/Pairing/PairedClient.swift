import Foundation

/// A client trusted via public-key fingerprint after pairing.
///
/// Fingerprint format: see `AuthPreamble.clientPublicKeyFingerprint`.
struct PairedClient: Codable, Identifiable, Equatable {
    let fingerprint: String
    let label: String
    let addedAt: Date

    var id: String { fingerprint }

    /// The key as the approval prompt and Settings show it: its two ends.
    static func shortFingerprint(_ fingerprint: String) -> String {
        guard fingerprint.count > 16 else { return fingerprint }
        return "\(fingerprint.prefix(8))…\(fingerprint.suffix(8))"
    }
}
