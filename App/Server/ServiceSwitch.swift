import OSLog

/// One service's switch and permission, as the menu and Settings drive them.
/// How it looks lives in `ServicePresentation`, keyed by the same ID.
struct ServiceSwitch: Identifiable {
    let entry: ServiceEntry
    private let readEnabled: () -> Bool
    private let writeEnabled: (Bool) -> Void

    init(entry: ServiceEntry, isEnabled: @escaping () -> Bool, setEnabled: @escaping (Bool) -> Void) {
        self.entry = entry
        self.readEnabled = isEnabled
        self.writeEnabled = setEnabled
    }

    var id: String { entry.id }
    var name: String { entry.name }
    var permission: ServicePermission { entry.service.permission }

    /// Whether the user has the service switched on, read from storage every
    /// time. This is deliberately not a `Binding`: switches are cached, and a
    /// `Binding` read while SwiftUI is updating views returns the value it
    /// held when it was created, so a cached one keeps reporting the state
    /// from app launch.
    var isEnabled: Bool {
        get { readEnabled() }
        nonmutating set { writeEnabled(newValue) }
    }

    var isActivated: Bool {
        get async {
            await entry.service.isActivated
        }
    }

    struct AccessRequest {
        let succeeded: Bool
        /// Whether the service can reach its data now.
        let isActivated: Bool
    }

    /// Runs `activate()`, which may raise a system prompt; it opens no
    /// window of its own. `AppStatusModel.requestAccess(for:)` calls this and
    /// records the answer.
    func requestAccess() async -> AccessRequest {
        do {
            try await entry.service.activate()
            return AccessRequest(succeeded: true, isActivated: true)
        } catch {
            Logger.server.error(
                "Activating \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return AccessRequest(succeeded: false, isActivated: await isActivated)
        }
    }

    static func fullDiskAccessNames(from switches: [ServiceSwitch]) -> [String] {
        switches.filter(\.permission.requiresFullDiskAccess).map(\.name)
    }
}
