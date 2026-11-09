import EventKit
import Foundation

/// The macOS permission a service needs, declared by the service itself. What
/// the menu badge and Settings say about it, where granting it happens, what
/// its tool errors say, and how the toggle reacts all come from here.
enum ServicePermission {
    case none
    case eventKit(EventKitEntity)
    case contacts
    case photos
    /// Apple Events to another app, through the Automation privacy pane.
    case automation(AutomationTarget)
    /// Camera, microphone, or Screen Recording; each tool asks for its own.
    case capture
    /// `hasPicker`: the database can also be reached by choosing it in a
    /// file picker, which switching the service off and on offers.
    case fullDiskAccess(hasPicker: Bool)
    /// Signing in to iCloud in the app's own window.
    case iCloudSignIn

    enum Guidance: Equatable {
        case systemSettings(URL)
        case iCloudSignIn
    }

    /// The Privacy & Security pane of a permission whose system prompt is
    /// the grant, and what its words call it.
    struct PrivacyPane {
        /// What a refusal says is not granted: "Calendar", "Notes automation".
        let subject: String
        /// What the badge and Settings say is needed.
        let access: String
        /// The pane's title in System Settings.
        let title: String
        let anchor: String
        var fullAccess = false
    }

    /// Only the permissions whose prompt is the grant have one. Capture has a
    /// pane per device, Full Disk Access has no prompt, and iCloud is signed
    /// in to in the app.
    var privacyPane: PrivacyPane? {
        switch self {
        case .eventKit(let entity):
            PrivacyPane(
                subject: entity.accessSubject,
                access: "\(entity.accessSubject) access",
                title: entity.settingsPane,
                anchor: "Privacy_\(entity.settingsPane)",
                fullAccess: true
            )
        case .contacts:
            PrivacyPane(subject: "Contacts", access: "Contacts access", title: "Contacts", anchor: "Privacy_Contacts")
        case .photos:
            PrivacyPane(subject: "Photos", access: "Photos access", title: "Photos", anchor: "Privacy_Photos")
        case .automation(let target):
            PrivacyPane(
                subject: "\(target.name) automation",
                access: "Automation access to control \(target.name)",
                title: "Automation",
                anchor: "Privacy_Automation"
            )
        case .none, .capture, .fullDiskAccess, .iCloudSignIn:
            nil
        }
    }

    /// The tool error for a permission the system refused. Every TCC denial
    /// a tool reports uses these words; a service whose one permission was
    /// refused throws its `deniedError`.
    static func notGranted(
        _ subject: String,
        pane: String,
        fullAccess: Bool = false,
        note: String? = nil
    ) -> ToolFailure {
        ToolFailure(
            "\(subject) access is not granted. \(grantInstruction(pane: pane, fullAccess: fullAccess))."
                + (note.map { " \($0)" } ?? "")
        )
    }

    private static func grantInstruction(pane: String, fullAccess: Bool = false) -> String {
        "Allow iMCP\(fullAccess ? " full access" : "") in System Settings > Privacy & Security > \(pane)"
    }

    /// The tool error when the system refused the prompt for this
    /// permission, which only a permission with a `privacyPane` has. Capture
    /// words each device's refusal with `notGranted`, and a Full Disk Access
    /// error says what could not be read, then `fullDiskAccessGrantInstruction`.
    var deniedError: ToolFailure {
        guard let pane = privacyPane else { preconditionFailure("\(self) has no prompt to refuse") }
        return Self.notGranted(pane.subject, pane: pane.title, fullAccess: pane.fullAccess)
    }

    static func settingsURL(anchor: String) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    static let fullDiskAccessPaneURL = settingsURL(anchor: "Privacy_AllFiles")

    /// Where the Full Disk Access grant is turned on. Settings, the service
    /// badges, and every Full Disk Access tool error share this sentence.
    static let fullDiskAccessGrantInstruction = grantInstruction(pane: "Full Disk Access") + "."

    /// The other way to a database that a picker can reach. The badge,
    /// Settings, and the tool error that finds no bookmark all end with it.
    static func pickerHint(choosing what: String) -> String {
        "Or switch the service off and on in the iMCP menu to choose \(what)."
    }

    /// What the menu's warning badge says while it is missing. The badge is
    /// itself what to click.
    var explanation: String? { describe(clickingGrants: true) }

    /// What the Settings row says while it is missing, beside its own Grant
    /// button.
    var settingsDetail: String? { describe(clickingGrants: false) }

    private func describe(clickingGrants: Bool) -> String? {
        if let pane = privacyPane {
            return clickingGrants
                ? "Needs \(pane.access). Click to grant, or enable iMCP under \(pane.title) in System Settings."
                : "Needs \(pane.access). You can also enable iMCP under \(pane.title) in System Settings."
        }
        switch self {
        case .capture:
            return "Needs Camera, Microphone, or Screen Recording access." + (clickingGrants ? " Click to grant." : "")
        case .fullDiskAccess(let hasPicker):
            return "Needs Full Disk Access to read this data. \(Self.fullDiskAccessGrantInstruction)"
                + (hasPicker ? " " + Self.pickerHint(choosing: "its database") : "")
        case .iCloudSignIn:
            return "Needs an iCloud sign-in to see where your people and devices are."
                + (clickingGrants ? " Click to sign in." : "")
        case .none, .eventKit, .contacts, .photos, .automation:
            return nil
        }
    }

    var guidance: Guidance? {
        if let pane = privacyPane { return .systemSettings(Self.settingsURL(anchor: pane.anchor)) }
        switch self {
        case .iCloudSignIn: return .iCloudSignIn
        case .capture: return .systemSettings(Self.settingsURL(anchor: "Privacy_Camera"))
        case .fullDiskAccess: return .systemSettings(Self.fullDiskAccessPaneURL)
        case .none, .eventKit, .contacts, .photos, .automation: return nil
        }
    }

    var requiresFullDiskAccess: Bool {
        if case .fullDiskAccess = self { return true }
        return false
    }

    /// Whether a failed `activate()` from the menu toggle leaves the service
    /// on. A permission the owner still has to grant elsewhere keeps it on,
    /// because the badge that leads there shows only while the service is
    /// on; snapping it off would make the click look broken.
    var keepsToggleOnAfterFailedActivation: Bool {
        switch self {
        case .capture, .iCloudSignIn: true
        case .none, .eventKit, .contacts, .photos, .automation, .fullDiskAccess: false
        }
    }

    /// Whether every tool call may run `activate()` first. For these the
    /// system prompt is the grant itself. Full Disk Access activation opens
    /// an alert and a file picker, Capture asks per tool for the one device
    /// it needs, and iCloud sign-in needs its window, so none of those runs
    /// from a tool.
    var activatesAtToolTime: Bool { privacyPane != nil }
}

/// An app another service drives with Apple Events.
struct AutomationTarget: Sendable {
    /// What the Automation pane calls it.
    let name: String
    let bundleIdentifier: String
}

/// How access to one EventKit entity is checked and requested, and the
/// Privacy pane its grant lives in. Calendar and Reminders each have one.
struct EventKitEntity: Sendable {
    let type: EKEntityType
    /// What the system's access denial is about, and its Privacy pane.
    let accessSubject: String
    let settingsPane: String

    static let events = EventKitEntity(type: .event, accessSubject: "Calendar", settingsPane: "Calendars")
    static let reminders = EventKitEntity(type: .reminder, accessSubject: "Reminders", settingsPane: "Reminders")
}
