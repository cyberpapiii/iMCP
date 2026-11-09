import Foundation

/// How long ago something happened, in the one wording the menu and the
/// Location window share. Coarse on purpose: it answers "is this alive", not
/// "when exactly".
enum RelativeAge {
    /// "just now", "4m ago", "3h ago", "2d ago".
    static func text(since date: Date, now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86400)d ago"
        }
    }
}
