import SwiftUI

/// A page of Settings, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case overview
    case general
    case permissions
    case clients
    case location
    case about

    /// The sidebar's blocks. `overview` sits above them, on its own.
    enum Group: CaseIterable {
        case setup
        case data
        case app
    }

    var id: Self { self }

    var group: Group? {
        switch self {
        case .overview: return nil
        case .general, .permissions, .clients: return .setup
        case .location: return .data
        case .about: return .app
        }
    }

    var title: String {
        switch self {
        case .overview: return "iMCP"
        case .general: return "General"
        case .permissions: return "Permissions"
        case .clients: return "Clients"
        case .location: return "Location"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "server.rack"
        case .general: return "gearshape.fill"
        case .permissions: return "lock.shield.fill"
        case .clients: return "app.connected.to.app.below.fill"
        case .location: return ServicePresentation.of("LocationService").iconName
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .overview, .permissions: return .blue
        case .general, .about: return .gray
        case .clients: return .teal
        case .location: return ServicePresentation.of("LocationService").color
        }
    }

    /// Words a search should find this page by, besides its title.
    private var keywords: [String] {
        switch self {
        case .overview: return ["server", "status", "running", "on", "off", "switch"]
        case .general: return ["menu bar", "login", "launch", "startup", "always", "running", "relaunch"]
        case .permissions:
            return ["full disk access", "icloud", "account", "sign in", "grant", "privacy", "services"]
        case .clients: return ["paired", "unpair", "agent", "connect", "claude", "codex"]
        case .location: return ["find my", "people", "history", "places", "visits"]
        case .about: return ["version", "github", "source", "issue", "bug", "copyright"]
        }
    }

    /// Whether a search, by any word in it, finds this page.
    func matches(_ search: String) -> Bool {
        let words = search.lowercased().split(separator: " ")
        guard !words.isEmpty else { return true }
        let haystack = ([title] + keywords).joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

/// The pages visited, for Back and Forward. Going back and then to a new page
/// drops the pages ahead, as a browser does.
struct SettingsHistory {
    private var pages: [SettingsPane] = [.overview]
    private var index = 0

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < pages.count - 1 }

    /// Records a page the owner chose. Choosing the page already shown, which
    /// is also what Back and Forward lead to, records nothing.
    mutating func visit(_ pane: SettingsPane) {
        guard pages[index] != pane else { return }
        pages = Array(pages[...index]) + [pane]
        index += 1
    }

    mutating func back() -> SettingsPane {
        if canGoBack { index -= 1 }
        return pages[index]
    }

    mutating func forward() -> SettingsPane {
        if canGoForward { index += 1 }
        return pages[index]
    }
}

/// The answer a permission row in Settings gives.
enum ServicePermissionStatus: Equatable {
    case checking
    case granted
    case notGranted
    case notEnabled

    /// Whether a permission is granted. Nil is still checking.
    init(granted: Bool?) {
        switch granted {
        case nil: self = .checking
        case true?: self = .granted
        case false?: self = .notGranted
        }
    }

    /// The iCloud account, labelled by the same answer that orders its row.
    init(_ iCloud: ICloudStatus.Report) {
        if iCloud.needsOwner {
            self = .notGranted
        } else {
            self = iCloud.isWorking ? .checking : .granted
        }
    }

    var needsOwner: Bool { self == .notGranted }
}

/// The same items with the ones that need the owner moved to the front. The
/// order is otherwise kept, so a row only moves when its own answer changes.
func missingFirst<Item>(_ items: [Item], status: (Item) -> ServicePermissionStatus) -> [Item] {
    items.filter { status($0).needsOwner } + items.filter { !status($0).needsOwner }
}

/// What the owner is asked before paired clients are forgotten.
struct UnpairRequest: Equatable {
    /// Nil means every paired client.
    var fingerprints: [String]?
    var title: String
    var message: String
    var confirmLabel: String

    static let all = UnpairRequest(
        fingerprints: nil,
        title: "Unpair All Clients?",
        message: "Every paired client will have to ask for approval again before it can connect.",
        confirmLabel: "Unpair All"
    )

    static func clients(_ clients: [PairedClient]) -> UnpairRequest? {
        guard let first = clients.first else { return nil }
        let fingerprints = clients.map(\.fingerprint)
        guard clients.count == 1 else {
            return UnpairRequest(
                fingerprints: fingerprints,
                title: "Unpair \(clients.count) Clients?",
                message: "They will have to ask for approval again before they can connect.",
                confirmLabel: "Unpair"
            )
        }
        let name = first.label.isEmpty ? "This client" : first.label
        return UnpairRequest(
            fingerprints: fingerprints,
            title: "Unpair Client?",
            message: "\(name) will have to ask for approval again before it can connect.",
            confirmLabel: "Unpair"
        )
    }
}
