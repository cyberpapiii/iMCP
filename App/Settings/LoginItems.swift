import AppKit
import Combine
import ServiceManagement

/// How iMCP starts at login: as the app's own login item, or through the
/// always-on agent, which also relaunches it whenever it quits. Each switch
/// asks the system for the change when it is set, then shows what the system
/// says, because registration can land in `.requiresApproval` and the owner
/// approves or revokes in System Settings while Settings is open.
@MainActor
final class LoginItemsModel: ObservableObject {
    /// The ServiceManagement calls, replaceable in tests.
    struct System {
        var mainAppStatus: () -> SMAppService.Status
        var agentStatus: () -> SMAppService.Status
        var setMainAppRegistered: (Bool) throws -> Void
        var setAlwaysOn: (Bool) throws -> Void

        static var live: System {
            System(
                mainAppStatus: { SMAppService.mainApp.status },
                agentStatus: { AlwaysOnService.agent.status },
                setMainAppRegistered: { register in
                    if register {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                },
                setAlwaysOn: { try AlwaysOnService.setEnabled($0) }
            )
        }
    }

    @Published private var mainAppEnabled = false
    @Published private var agentEnabled = false
    @Published private(set) var approvalNeeded = false
    @Published private(set) var error: String?

    private let system: System
    private var activations: AnyCancellable?

    /// Reads the system's answer now and each time the app comes to the
    /// front, where the owner returns after approving in System Settings.
    init(system: System = .live) {
        self.system = system
        refresh()
        activations = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
    }

    /// On while the agent is, since the agent starts the app at login too.
    var launchAtLogin: Bool {
        get { mainAppEnabled || agentEnabled }
        set { apply { try system.setMainAppRegistered(newValue) } }
    }

    var alwaysOn: Bool {
        get { agentEnabled }
        set { apply { try system.setAlwaysOn(newValue) } }
    }

    func refresh() {
        let mainApp = system.mainAppStatus()
        let agent = system.agentStatus()
        mainAppEnabled = mainApp == .enabled
        agentEnabled = AlwaysOnService.isEnabled(agent)
        approvalNeeded = mainApp == .requiresApproval || agent == .requiresApproval
    }

    private func apply(_ change: () throws -> Void) {
        error = nil
        do {
            try change()
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}
