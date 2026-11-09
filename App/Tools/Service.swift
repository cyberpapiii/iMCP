@preconcurrency
protocol Service {
    @ToolBuilder var tools: [Tool] { get }

    /// What the service needs from macOS before `activate()` can succeed.
    var permission: ServicePermission { get }

    var isActivated: Bool { get async }
    /// Requests the permission: may raise a system prompt, or for Full Disk
    /// Access an alert and a file picker. It never opens System Settings;
    /// `GuidanceRouter` does that.
    func activate() async throws
    /// The enabled-service set gained or lost this service. Separate from
    /// `activate()`, which requests permission and must not run for every
    /// already-enabled service at launch.
    func enablementDidChange(enabled: Bool) async
}

extension Service {
    var permission: ServicePermission { .none }

    var isActivated: Bool {
        get async {
            return true
        }
    }

    func activate() async throws {}

    func enablementDidChange(enabled: Bool) async {}

    /// `tools` as a client calls them: when the permission allows it, each
    /// call runs `activate()` first, so a first call raises the system prompt.
    var callableTools: [Tool] {
        guard permission.activatesAtToolTime else { return tools }
        return tools.map { tool in tool.preceded { try await self.activate() } }
    }
}

@resultBuilder
struct ToolBuilder {
    static func buildBlock(_ tools: Tool...) -> [Tool] {
        tools
    }
}
