import Foundation

/// One line of status in the menu bar: a dot, a title, and what the dot means.
/// Pure so the menu's wording is testable without a session or a Keychain.
struct StatusSummary: Equatable {
    /// Ordered from fine to worst, so the worst of several rows is their `max`.
    enum Level: Int, Comparable {
        /// Working; nothing to do.
        case ok
        /// Working on it, or something the user can fix in one click.
        case attention
        /// Not working until the user acts.
        case problem

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var level: Level
    var title: String
    var detail: String
}

/// Where a click on a status row takes the owner.
enum StatusDestination: Equatable {
    case fullDiskAccessPane
    case settings
    case iCloudSignIn

    /// Tells VoiceOver where the row leads.
    var hint: String {
        switch self {
        case .fullDiskAccessPane: return "Opens Full Disk Access in System Settings"
        case .settings: return "Opens Settings"
        case .iCloudSignIn: return "Opens the iCloud sign-in window"
        }
    }
}

func joinedEnglishList(_ items: [String]) -> String {
    switch items.count {
    case 0:
        return ""
    case 1:
        return items[0]
    case 2:
        return "\(items[0]) and \(items[1])"
    default:
        return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
    }
}
