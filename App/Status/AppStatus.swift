import Foundation

enum FullDiskAccessStatus {
    static func summary(requiredBy names: [String], granted: Bool) -> StatusSummary {
        StatusSummary(level: granted ? .ok : .attention, title: "Full Disk Access", detail: neededBy(names))
    }

    static func neededBy(_ names: [String]) -> String {
        "Needed by \(joinedEnglishList(names))"
    }

    /// The row's words with room to say where the grant is turned on.
    static func explanation(requiredBy names: [String], needsOwner: Bool) -> String {
        needsOwner ? "\(neededBy(names)). \(ServicePermission.fullDiskAccessGrantInstruction)" : neededBy(names)
    }
}

/// What the menu and Settings say while no client can connect.
enum ListenerStatus {
    static let failed = StatusSummary(
        level: .problem,
        title: "Server",
        detail: "Clients cannot connect; turn iMCP off and on again"
    )
}

/// What the menu and the Clients page of Settings say about paired clients.
enum ClientsStatus {
    static let unreadable = "Could not read paired clients. \(ICloudStatus.unlockKeychain)"
    static let noneYet = "No paired clients yet. Each connection asks for your approval."

    /// `pairedCount` is nil when the paired-client store could not be read.
    static func summary(pairedCount: Int?) -> StatusSummary {
        guard let pairedCount else {
            return StatusSummary(level: .attention, title: "Clients", detail: unreadable)
        }
        let detail: String
        switch pairedCount {
        case 0: detail = noneYet
        case 1: detail = "1 paired client"
        default: detail = "\(pairedCount) paired clients"
        }
        return StatusSummary(level: .ok, title: "Clients", detail: detail)
    }
}

/// The answer to "is it fine, and if not, what is wrong": the worst level
/// among the rows that apply, and one line naming the trouble.
struct OverallStatus: Equatable {
    var level: StatusSummary.Level
    var headline: String

    /// The headline, the menu, and the icon's VoiceOver text all say this
    /// while nothing is wrong.
    static let allGood = "Everything is working"

    init(rows: [StatusSummary]) {
        let troubled = rows.filter { $0.level != .ok }
        // `max(by:)` keeps the first of equals, so rows listed earlier win a tie.
        guard let worst = troubled.max(by: { $0.level < $1.level }) else {
            self.level = .ok
            self.headline = Self.allGood
            return
        }
        self.level = worst.level
        let others = troubled.count - 1
        self.headline = "\(worst.title): \(worst.detail)" + (others > 0 ? ", and \(others) more" : "")
    }
}

/// Everything the app knows about its own health at one moment. The menu-bar
/// icon, the menu and Settings read this one value, so they cannot say
/// different things. The Location window words its iCloud line with the same
/// `ICloudStatus.summary`.
struct AppStatus: Equatable {
    /// Whether Full Disk Access is as good as granted: the grant itself, or
    /// every service that is on and needs it reaching its database through
    /// the file it was given. Nil until the first check finishes.
    var fullDiskAccessGranted: Bool?
    /// Whether each service that is on can reach its data, by service ID.
    /// The menu badge, the Settings rows, and `fullDiskAccessGranted` all
    /// read this one answer. A service with no entry is still being checked.
    var serviceAccess: [String: Bool] = [:]
    /// The services that are on and need Full Disk Access.
    var fullDiskAccessNames: [String] = []
    /// Every service that would need it, on or off.
    var fullDiskAccessCapableNames: [String] = []
    var locationEnabled = false
    /// iMCP is on and nothing is listening for clients.
    var listenerFailed = false
    var iCloud: ICloudStatus.Report
    var clients: StatusSummary

    /// The services the grant is described as needed by: the ones that are
    /// on, or, when none of those needs it, the ones that would. Settings
    /// shows the row either way.
    var fullDiskAccessNeededBy: [String] {
        fullDiskAccessNames.isEmpty ? fullDiskAccessCapableNames : fullDiskAccessNames
    }

    var fullDiskAccess: StatusSummary? {
        fullDiskAccessGranted.map {
            FullDiskAccessStatus.summary(requiredBy: fullDiskAccessNeededBy, granted: $0)
        }
    }

    /// One row of the status list: what it is about, what it says, and where
    /// a click on it leads.
    struct Row: Equatable, Identifiable {
        enum Subject {
            case server
            case fullDiskAccess
            case iCloud
            case clients
        }

        var subject: Subject
        var summary: StatusSummary
        var destination: StatusDestination
        var id: Subject { subject }
        var hint: String { destination.hint }
    }

    /// The rows that apply now, in the order they are listed: the server
    /// only while it cannot listen, Full Disk Access only while a service
    /// that is on needs it, iCloud only while Location is on.
    var subjectRows: [Row] {
        var rows: [Row] = []
        if listenerFailed {
            rows.append(Row(subject: .server, summary: ListenerStatus.failed, destination: .settings))
        }
        if !fullDiskAccessNames.isEmpty, let fullDiskAccess {
            rows.append(Row(subject: .fullDiskAccess, summary: fullDiskAccess, destination: .fullDiskAccessPane))
        }
        if locationEnabled {
            rows.append(Row(subject: .iCloud, summary: iCloud.summary, destination: iCloud.destination))
        }
        rows.append(Row(subject: .clients, summary: clients, destination: .settings))
        return rows
    }

    var rows: [StatusSummary] { subjectRows.map(\.summary) }

    /// The rows the menu shows: only the ones that are not fine. Empty means
    /// the menu says `OverallStatus.allGood`; Settings still lists the
    /// healthy details.
    var rowsNeedingOwner: [Row] { subjectRows.filter { $0.summary.level != .ok } }

    var overall: OverallStatus { OverallStatus(rows: rows) }
}

/// What the menu-bar item shows and says. The dot appears only while the
/// server is on: a server that is off has nothing to be wrong with.
struct MenuBarIndicator: Equatable {
    enum Icon: Equatable {
        case off
        case on
        case attention
    }

    var icon: Icon
    var accessibilityDescription: String

    init(serverEnabled: Bool, overall: OverallStatus) {
        guard serverEnabled else {
            self.icon = .off
            self.accessibilityDescription = "iMCP is off"
            return
        }
        if overall.level == .ok {
            self.icon = .on
            self.accessibilityDescription = "iMCP is on. \(overall.headline)"
        } else {
            self.icon = .attention
            self.accessibilityDescription = "iMCP needs attention. \(overall.headline)"
        }
    }
}
