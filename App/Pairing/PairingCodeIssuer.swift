import Combine
import Foundation

/// Issues one-time pairing codes. Codes live in memory only, so quitting the
/// app invalidates whatever was outstanding.
///
/// At most one code is active. A code expires after five minutes and is
/// discarded by the first successful validation, so a replayed auth response
/// carrying the same code will not pair a second client. Three wrong
/// submissions discard the code.
@MainActor
final class PairingCodeIssuer {
    nonisolated static let codeLifetime: TimeInterval = 5 * 60
    nonisolated static let maxFailedAttempts = 3

    /// How the active code stopped being usable before its expiry.
    enum Event: Equatable {
        /// A client presented it. That client pairs once its session is admitted.
        case redeemed(code: String)
        /// Guessed at `maxFailedAttempts` times.
        case exhausted(code: String)
    }

    private struct ActiveCode {
        let code: String
        let expiresAt: Date
        var failedAttempts = 0
    }

    private var activeCode: ActiveCode?

    /// One for each code that stops being usable before its expiry.
    let events = PassthroughSubject<Event, Never>()

    nonisolated init() {}

    func issue(at date: Date = Date()) -> (code: String, expiresAt: Date) {
        let code = Self.generateCode()
        let expiresAt = date.addingTimeInterval(Self.codeLifetime)
        activeCode = ActiveCode(code: code, expiresAt: expiresAt)
        return (code, expiresAt)
    }

    func validate(_ submittedCode: String, at date: Date = Date()) -> Bool {
        guard var current = activeCode, date <= current.expiresAt else { return false }
        guard PairingCode.normalize(submittedCode) == current.code else {
            current.failedAttempts += 1
            if current.failedAttempts < Self.maxFailedAttempts {
                activeCode = current
            } else {
                activeCode = nil
                events.send(.exhausted(code: current.code))
            }
            return false
        }
        activeCode = nil
        events.send(.redeemed(code: current.code))
        return true
    }

    private static func generateCode() -> String {
        let length = Int.random(in: PairingCode.lengths)
        let alphabet = Array(PairingCode.alphabet)
        return String((0 ..< length).map { _ in alphabet.randomElement()! })
    }
}
