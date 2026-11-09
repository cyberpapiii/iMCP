import Foundation
import MCP
import Network
import OSLog

/// The listener and every connection it accepts, from the first byte to the
/// close: authentication, the approval decision, pairing, tool gating, and
/// removal.
actor ServerNetworkManager {
    private struct Connection {
        var session = ConnectionSession()
        let manager: MCPConnectionManager
        var approval: Task<ApprovalAnswer, Never>?
        var setupDeadline: Task<Void, Never>?
    }

    /// Waiting on the approval prompt is the only way a session outlives the
    /// setup deadline without the user or a paired key, so this is the count
    /// that bounds what a peer can pin. Checked there and not when the socket
    /// is accepted: a cap on accepted sockets would let any local process
    /// lock out a paired client by holding that many connections open.
    static let maxSessionsAwaitingApproval = 32

    private let listener: NetworkDiscoveryManager?
    private let pairedClients: PairedClientStore
    private let pairingCodes: PairingCodeIssuer
    private let prompt: ApprovalPrompt
    private let entries: [ServiceEntry]
    private let clock: WallClock
    private let pairedLookup: Duration

    private var connections: [UUID: Connection] = [:]
    /// What the listener is doing, as last read from it.
    private(set) var listenerState = NetworkDiscoveryManager.State.stopped
    /// Every change of `listenerState`, for the one reader that shows it.
    nonisolated let listenerStates: AsyncStream<NetworkDiscoveryManager.State>
    private let listenerStatesContinuation: AsyncStream<NetworkDiscoveryManager.State>.Continuation
    private var isEnabledState = true
    private(set) var enabledServiceIDs: Set<String> = []
    private var catalog: ToolCatalog?

    /// `listener` nil keeps the manager from ever listening; connections can
    /// still be handed to `accept`.
    init(
        listener: NetworkDiscoveryManager?,
        pairedClients: PairedClientStore,
        pairingCodes: PairingCodeIssuer,
        entries: [ServiceEntry],
        clock: WallClock,
        pairedLookup: Duration = HandshakeDeadline.pairedLookup,
        prompt: @escaping ApprovalPrompt
    ) {
        self.listener = listener
        self.pairedClients = pairedClients
        self.pairingCodes = pairingCodes
        self.entries = entries
        self.clock = clock
        self.pairedLookup = pairedLookup
        self.prompt = prompt
        (listenerStates, listenerStatesContinuation) = AsyncStream.makeStream()
    }

    // MARK: - Listener

    func setEnabled(_ enabled: Bool) async {
        isEnabledState = enabled
        Logger.server.info("iMCP enabled state changed to: \(enabled)")
        if enabled {
            await start()
        } else {
            await stop()
        }
    }

    private func start() async {
        guard let listener else {
            Logger.server.notice("Not listening: this host has no network listener")
            return
        }
        Logger.server.info("Starting network manager")
        await listener.start(
            onChange: { [weak self] in
                Task { await self?.listenerChanged() }
            },
            onConnection: { [weak self] connection in
                Task { await self?.accept(connection) }
            }
        )
    }

    private func stop() async {
        if let listener {
            Logger.server.info("Stopping network manager")
            await listener.stop()
            await listenerChanged()
        }
        for id in Array(connections.keys) {
            await removeConnection(id)
        }
    }

    /// Reads the listener's state now, so a change reported late or out of
    /// order still lands on the current one.
    private func listenerChanged() async {
        guard let state = await listener?.state, state != listenerState else { return }
        listenerState = state
        switch state {
        case .listening(let port):
            // Publish the port for the CLI's loopback fast path. Bonjour
            // resolution hangs when the client lacks Local Network permission.
            publishListenerEndpoint(port: port)
        case .stopped:
            ListenerEndpointFile.remove()
        case .starting, .failed:
            // The file keeps the old port until a listener is ready again. A
            // stale port only bumps the CLI to its Bonjour fallback.
            break
        }
        listenerStatesContinuation.yield(state)
    }

    // MARK: - Enabled services

    func updateEnabledServices(_ ids: Set<String>) async {
        guard enabledServiceIDs != ids else { return }
        enabledServiceIDs = ids

        if case .listening(let port) = listenerState {
            publishListenerEndpoint(port: port)
        }

        notifyApprovedToolListChanged()
    }

    private func publishListenerEndpoint(port: UInt16) {
        do {
            let names = entries.filter { enabledServiceIDs.contains($0.id) }.map(\.name).sorted()
            try ListenerEndpointFile.write(port: port, enabledServices: names)
            Logger.server.info("Wrote listener endpoint file (port \(port))")
        } catch {
            Logger.server.error("Failed to write listener endpoint file: \(error)")
        }
    }

    /// Only approved connections get told; the rest see no tools anyway.
    private func notifyApprovedToolListChanged() {
        let managers = connections.values.filter(\.session.isApproved).map(\.manager)
        Task {
            for manager in managers {
                await manager.notifyToolListChanged()
            }
        }
    }

    // MARK: - Connections

    func accept(_ connection: NWConnection) {
        let id = UUID()
        Logger.server.info("Handling new connection: \(id)")

        let manager = MCPConnectionManager(connectionID: id, connection: connection, hooks: hooks(for: id))
        var entry = Connection(manager: manager)
        let clock = clock
        let deadline = clock.date(after: HandshakeDeadline.setup)
        entry.setupDeadline = Task { [weak self] in
            guard (try? await clock.sleepUntil(deadline)) != nil else { return }
            await self?.closeIfStalled(id)
        }
        connections[id] = entry

        Task { [weak self] in
            do {
                try await manager.start()
                Logger.server.notice("Connection \(id) successfully established")
            } catch {
                Logger.server.error("Failed to establish connection \(id): \(error)")
                await self?.removeConnection(id)
            }
        }
    }

    private func hooks(for id: UUID) -> ConnectionHooks {
        ConnectionHooks(
            authResponse: { [weak self] challenge, response in
                await self?.processAuthResponse(connectionID: id, challenge: challenge, response: response)
            },
            admit: { [weak self] clientInfo in
                await self?.admit(id, clientInfo: clientInfo) ?? false
            },
            serve: { [weak self] server in
                await self?.registerHandlers(for: server, connectionID: id)
            },
            closed: { [weak self] in
                await self?.removeConnection(id)
            }
        )
    }

    func isConnectionApproved(_ id: UUID) -> Bool {
        connections[id]?.session.isApproved ?? false
    }

    func removeConnection(_ id: UUID) async {
        guard var entry = connections[id] else {
            Logger.server.debug("Connection \(id) already removed, skipping")
            return
        }
        guard entry.session.phase != .removing else {
            Logger.server.debug("Connection \(id) removal already in progress, skipping")
            return
        }

        entry.session.phase = .removing
        connections[id] = entry
        Logger.server.debug("Removing connection: \(id)")

        entry.setupDeadline?.cancel()
        // Withdraws a request still on the approval prompt.
        entry.approval?.cancel()
        await entry.manager.stop()
        connections.removeValue(forKey: id)
    }

    /// Runs in the setup deadline's task, so a cancel that lands after its
    /// sleep ended but before it reached the actor still stops it.
    private func closeIfStalled(_ id: UUID) async {
        guard !Task.isCancelled, let session = connections[id]?.session, session.isStalledSetup else { return }
        Logger.server.warning("Connection \(id) setup timed out, closing it")
        await removeConnection(id)
    }

    private func closeIfUnapproved(_ id: UUID) async {
        guard var entry = connections[id], !entry.session.isApproved else { return }
        let limitReached = entry.session.recordUnapprovedRequest()
        connections[id] = entry
        guard limitReached else { return }
        Logger.server.error(
            "Closing unapproved connection \(id, privacy: .public) after \(entry.session.unapprovedRequests) rejected requests"
        )
        await removeConnection(id)
    }

    // MARK: - Authentication and admission

    func processAuthResponse(
        connectionID: UUID,
        challenge: AuthChallengeFrame,
        response: AuthResponseFrame
    ) async {
        guard challenge.connectionID == connectionID else {
            Logger.server.warning("Auth response connection ID mismatch for \(connectionID)")
            return
        }

        guard let currentAuth = connections[connectionID]?.session.auth else { return }

        // One-shot: a second AUTH-RESPONSE must not upgrade trust mid-approval.
        guard case .none = currentAuth else {
            Logger.server.debug("Ignoring duplicate auth response for \(connectionID)")
            return
        }

        guard
            let fingerprint = AuthResponseFrame.verifiedFingerprint(
                response: response,
                challenge: challenge
            )
        else {
            connections[connectionID]?.session.auth = .invalidSignature
            Logger.server.notice(
                "\(AuthPreambleDiagnostics.invalidSignature) connection=\(connectionID)"
            )
            return
        }

        if await pairedClients.contains(fingerprint: fingerprint, within: pairedLookup) {
            connections[connectionID]?.session.auth = .preAuthenticated(fingerprint: fingerprint, byCode: false)
            Logger.server.notice(
                "\(AuthPreambleDiagnostics.verifiedPaired) connection=\(connectionID)"
            )
            return
        }

        if let submittedCode = response.pairingCode, await pairingCodes.validate(submittedCode) {
            // The session may have been removed during the await; this then writes nothing.
            connections[connectionID]?.session.auth = .preAuthenticated(fingerprint: fingerprint, byCode: true)
            Logger.server.notice(
                "\(AuthPreambleDiagnostics.verifiedPaired) connection=\(connectionID) via-pairing-code"
            )
            return
        }

        if response.pairingCode != nil {
            Logger.server.warning("Invalid or expired pairing code for connection \(connectionID)")
        }

        connections[connectionID]?.session.auth = .verifiedUnpaired(fingerprint: fingerprint)
        Logger.server.notice(
            "\(AuthPreambleDiagnostics.verifiedUnpaired) connection=\(connectionID)"
        )
    }

    private var hasRoomToAwaitApproval: Bool {
        connections.values.count(where: { $0.session.phase == .awaitingApproval })
            < Self.maxSessionsAwaitingApproval
    }

    /// The client's initialize: decides, asks if it must, pairs if it was
    /// asked to, and marks the session approved. False closes the connection.
    private func admit(_ id: UUID, clientInfo: MCP.Client.Info) async -> Bool {
        guard let session = connections[id]?.session else { return false }
        let clientName = Self.sanitizedClientName(clientInfo.name)

        if case .none = session.auth {
            Logger.server.notice("\(AuthPreambleDiagnostics.noResponseGrace) connection=\(id)")
        }

        let pairing: (fingerprint: String, route: PairingOutcome.Route)?
        switch session.admission(hasRoomToAwaitApproval: hasRoomToAwaitApproval) {
        case .admit(let pairsByCode):
            Logger.server.info("Auto-approving pre-authenticated connection \(id)")
            pairing = pairsByCode ? session.verifiedFingerprint.map { ($0, .pairingCode) } : nil
        case .deny(.invalidSignature):
            Logger.server.notice("Denying connection \(id): auth response did not verify")
            return false
        case .deny(.approvalQueueFull):
            Logger.server.warning("Denying connection \(id): approval queue is full")
            return false
        case .ask:
            let request = ConnectionApprovalRequest(
                connectionID: id,
                clientName: clientName,
                verifiedFingerprint: session.verifiedFingerprint
            )
            let answer = await askForApproval(request)
            guard answer != .denied else { return false }
            // The person's decision stands even if the connection closed
            // while it was on its way. Only a key the preamble verified is paired.
            pairing = answer == .approved(pair: true) ? request.verifiedFingerprint.map { ($0, .approval) } : nil
        }

        if let pairing {
            // The save is bounded by its own deadline. Left to the setup
            // deadline it could close the session after its key was saved.
            connections[id]?.setupDeadline?.cancel()
            await pairedClients.pair(
                PairedClient(fingerprint: pairing.fingerprint, label: clientName, addedAt: Date()),
                route: pairing.route
            )
        }

        // Closed while the prompt was up, or while pairing: approving a
        // removed connection must not leak it into the approved set.
        guard var entry = connections[id], entry.session.phase != .removing else {
            Logger.server.debug("Ignoring approval for removed connection: \(id)")
            return false
        }
        entry.session.phase = .approved
        entry.setupDeadline?.cancel()
        connections[id] = entry
        return true
    }

    /// The name a client reports about itself. Untrusted: it is shown in the
    /// approval dialog and stored as the paired client's label, so it is
    /// reduced to one bounded line with no control or formatting characters.
    /// Scalars are bounded too, because one character can carry any number of
    /// combining marks.
    static func sanitizedClientName(_ name: String) -> String {
        let scalars = name.unicodeScalars.lazy.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }.prefix(256)
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Unknown client" : String(cleaned.prefix(64))
    }

    private func askForApproval(_ request: ConnectionApprovalRequest) async -> ApprovalAnswer {
        let id = request.connectionID
        guard var entry = connections[id] else { return .denied }
        let prompt = self.prompt
        let approval = Task { await prompt(request) }
        entry.approval = approval
        entry.session.phase = .awaitingApproval
        connections[id] = entry

        let answer = await approval.value
        if var entry = connections[id], entry.session.phase == .awaitingApproval {
            entry.approval = nil
            entry.session.phase = .settingUp
            connections[id] = entry
        }
        return answer
    }

    // MARK: - Requests

    private func toolCatalog() throws -> ToolCatalog {
        if let catalog { return catalog }
        let built = try ToolCatalog(entries: entries)
        catalog = built
        return built
    }

    private func registerHandlers(for server: MCP.Server, connectionID: UUID) async {
        await server.withMethodHandler(ListPrompts.self) { _ in
            Logger.server.debug("Handling ListPrompts request for \(connectionID)")
            return ListPrompts.Result(prompts: [])
        }

        await server.withMethodHandler(ListResources.self) { _ in
            Logger.server.debug("Handling ListResources request for \(connectionID)")
            return ListResources.Result(resources: [])
        }

        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self else {
                return ListTools.Result(tools: [])
            }

            Logger.server.debug("Handling ListTools request for \(connectionID)")

            guard await self.isConnectionApproved(connectionID) else {
                Logger.server.warning(
                    "ListTools rejected for unapproved connection: \(connectionID, privacy: .public)"
                )
                await self.closeIfUnapproved(connectionID)
                throw MCPError.internalError(
                    "iMCP connection is not approved. Approve the client in iMCP; if it is already paired, reconnect."
                )
            }

            var tools: [MCP.Tool] = []
            if await self.isEnabledState {
                tools = try await self.toolCatalog().tools(enabled: self.enabledServiceIDs)
            }

            Logger.server.debug("Returning \(tools.count) available tools for \(connectionID)")
            return ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return CallTool.Result(
                    content: [.text(text: "Server unavailable", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            Logger.server.debug("Tool call received from \(connectionID): \(params.name)")

            guard await self.isConnectionApproved(connectionID) else {
                Logger.server.warning(
                    "Tool call rejected for unapproved connection: \(connectionID, privacy: .public)"
                )
                await self.closeIfUnapproved(connectionID)
                return CallTool.Result(
                    content: [
                        .text(
                            text: "Connection is not approved. Please approve the client in iMCP.",
                            annotations: nil,
                            _meta: nil
                        )
                    ],
                    isError: true
                )
            }

            // Reachable between switching iMCP off and the session's removal.
            guard await self.isEnabledState else {
                Logger.server.notice("Tool call rejected: iMCP is disabled")
                return CallTool.Result(
                    content: [
                        .text(
                            text: "iMCP is currently disabled. Please enable it to use tools.",
                            annotations: nil,
                            _meta: nil
                        )
                    ],
                    isError: true
                )
            }

            do {
                let result = try await self.toolCatalog().call(
                    named: params.name,
                    arguments: params.arguments ?? [:],
                    enabled: self.enabledServiceIDs
                )
                Logger.server.debug("Tool \(params.name) executed successfully for \(connectionID)")
                return result
            } catch {
                return ToolCatalog.errorResult(for: error, toolName: params.name)
            }
        }
    }
}
