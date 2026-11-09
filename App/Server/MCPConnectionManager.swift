import Foundation
import MCP
import Network
import OSLog

/// What a connection reports to whoever owns its session.
struct ConnectionHooks: Sendable {
    /// Awaited before any later frame from the client reaches the SDK.
    let authResponse: @Sendable (AuthChallengeFrame, AuthResponseFrame) async -> Void
    /// The client's initialize. True lets it in.
    let admit: @Sendable (MCP.Client.Info) async -> Bool
    /// Registers the request handlers once the transport is live.
    let serve: @Sendable (MCP.Server) async -> Void
    /// The connection closed, from either end. Called once.
    let closed: @Sendable () async -> Void
}

/// One instance per accepted `NWConnection`, never shared.
actor MCPConnectionManager {
    /// The SDK writes the initialize error only after the hook throws, and
    /// says nothing once it is sent. Closing at once would drop it.
    private static let denialFlushDelay: Duration = .milliseconds(100)

    private let connectionID: UUID
    private let server: MCP.Server
    private let transport: NWConnectionTransport
    private let hooks: ConnectionHooks

    init(connectionID: UUID, connection: NWConnection, hooks: ConnectionHooks) {
        self.connectionID = connectionID
        self.hooks = hooks
        self.transport = NWConnectionTransport(
            connection: connection,
            connectionID: connectionID,
            onAuthResponse: hooks.authResponse,
            onClose: hooks.closed
        )
        self.server = MCP.Server(
            name: Bundle.main.name ?? "iMCP",
            version: Bundle.main.shortVersionString ?? "unknown",
            capabilities: MCP.Server.Capabilities(
                tools: .init(listChanged: true)
            )
        )
    }

    func start() async throws {
        Logger.server.notice("Starting MCP server for connection: \(self.connectionID)")

        let connectionID = connectionID
        try await server.start(transport: transport) { [weak self, hooks] clientInfo, _ in
            guard self != nil else { throw MCPError.connectionClosed }

            Logger.server.info("Received initialize request from client: \(clientInfo.name)")

            let approved = await hooks.admit(clientInfo)
            Logger.server.info(
                "Approval result for connection \(connectionID): \(approved ? "Approved" : "Denied")"
            )

            guard approved else {
                Task { [weak self] in
                    try? await Task.sleep(for: MCPConnectionManager.denialFlushDelay)
                    await self?.stop()
                }
                throw MCPConnectionDenial.error
            }
        }

        Logger.server.notice("MCP Server started successfully for connection: \(self.connectionID)")

        // Handlers go live with the transport, which can be before the
        // initialize hook resolves. Unapproved sessions are refused per
        // request and closed after repeated attempts.
        await hooks.serve(server)
    }

    func notifyToolListChanged() async {
        do {
            Logger.server.debug("Notifying client that tool list changed")
            try await server.notify(ToolListChangedNotification.message())
        } catch {
            Logger.server.error("Failed to notify client of tool list change: \(error)")

            if isClosedSocketError(error) {
                Logger.server.debug("Connection appears to be closed")
                await stop()
            }
        }
    }

    /// Closes the connection. The transport reports it through `hooks.closed`.
    func stop() async {
        await server.stop()
        // The server reaches the transport only once it has started; a
        // connection stopped before that still has to be closed.
        await transport.disconnect()
    }
}

/// Distinct from `MCPError.connectionClosed` so a deny is not a dropped session.
enum MCPConnectionDenial {
    static let error = MCPError.invalidRequest(
        "iMCP connection denied. Approve the client in iMCP."
    )
}
