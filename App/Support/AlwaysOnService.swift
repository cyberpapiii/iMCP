import ServiceManagement

enum AlwaysOnService {
    static let agentPlistName = "co.dododo.iMCP.always-on.plist"

    static var agent: SMAppService {
        .agent(plistName: agentPlistName)
    }

    static var isEnabled: Bool { isEnabled(agent.status) }

    static func isEnabled(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval:
            true
        case .notFound, .notRegistered:
            false
        @unknown default:
            false
        }
    }

    /// Always-on agent starts iMCP at login itself, so registering both login
    /// mechanisms would create a startup race and duplicate launches.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard !isEnabled else { return }
            let restoreLaunchAtLogin = SMAppService.mainApp.status == .enabled
            if restoreLaunchAtLogin {
                try SMAppService.mainApp.unregister()
            }
            do {
                try agent.register()
            } catch {
                if restoreLaunchAtLogin {
                    try? SMAppService.mainApp.register()
                }
                throw error
            }
        } else if isEnabled {
            try agent.unregister()
        }
    }
}
