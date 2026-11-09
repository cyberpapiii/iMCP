import Foundation
import Logging
import MCP
import Network
import OSLog

/// Replaces the SDK's `NetworkTransport` for incoming connections. The
/// SDK's reconnection and heartbeat code keeps producing continuations that
/// resume twice or never resume (swift-sdk #137, #203, #214), and iMCP had
/// both features disabled anyway. This transport runs one connect cycle and
/// never reconnects, so a stale state handler from a prior cycle cannot exist.
///
/// Wire format is identical to the SDK's `NetworkTransport`: JSON-RPC
/// messages delimited by newlines, with heartbeat frames (which use the
/// SDK's magic-byte format and no delimiter) tolerated and dropped.
actor NWConnectionTransport: Transport {
    /// `Transport` requires a swift-log logger. The SDK is given one that
    /// discards everything; this transport logs through `Logger.server`.
    nonisolated let logger = Logging.Logger(
        label: "me.mattt.iMCP.transport",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )

    private static let receiveBufferSize = 65536

    private let connection: NWConnection
    private let connectionID: UUID
    private var authChallenge: AuthChallengeFrame?
    private let onAuthResponse: (@Sendable (AuthChallengeFrame, AuthResponseFrame) async -> Void)?
    private let onClose: @Sendable () async -> Void

    /// The lifecycle only moves forward. There is deliberately no path from
    /// `.stopped` back to `.connecting`.
    private enum State {
        case idle
        case connecting
        case connected
        case stopped
    }

    private var state: State = .idle
    private var receiveTask: Task<Void, Never>?

    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    /// `onClose` runs once, when the connection closes from either end.
    init(
        connection: NWConnection,
        connectionID: UUID,
        onAuthResponse: (@Sendable (AuthChallengeFrame, AuthResponseFrame) async -> Void)? = nil,
        onClose: @escaping @Sendable () async -> Void = {}
    ) {
        self.connection = connection
        self.connectionID = connectionID
        self.onAuthResponse = onAuthResponse
        self.onClose = onClose

        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    /// Callable once per transport instance; there is deliberately no
    /// reconnection path. State changes after readiness show up in the receive
    /// loop, not here.
    func connect() async throws {
        guard state == .idle else {
            throw MCPError.internalError("Transport already connected")
        }
        state = .connecting

        // From readiness on, terminal states show up as failing reads in the
        // receive loop.
        do {
            try await connection.startUntilReady(queue: DispatchQueue(label: "me.mattt.iMCP.transport"))
        } catch is CancellationError {
            throw MCPError.internalError("Connection cancelled")
        } catch {
            throw MCPError.transportError(error)
        }

        // disconnect() may have run while awaiting readiness.
        guard state == .connecting else { return }
        state = .connected

        let challenge = AuthChallengeFrame(connectionID: connectionID)
        authChallenge = challenge
        try await sendBytes(challenge.encode())
        Logger.server.notice(
            "\(AuthPreambleDiagnostics.challengeSent) connection=\(self.connectionID)"
        )

        receiveTask = Task { await self.receiveLoop() }
        Logger.server.debug("Transport connected connection=\(self.connectionID)")
    }

    func disconnect() async {
        guard state != .stopped else { return }
        state = .stopped

        receiveTask?.cancel()
        receiveTask = nil

        connection.cancel()
        messageContinuation.finish()
        Logger.server.debug("Transport disconnected connection=\(self.connectionID)")
        await onClose()
    }

    func send(_ message: Data) async throws {
        try await sendBytes(MessageFrameScanner.frame(message))
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }

    private func receiveLoop() async {
        var scanner = MessageFrameScanner(maxMessageBytes: WireContract.maxClientMessageBytes)

        while state == .connected, !Task.isCancelled {
            let chunk: Data
            let isComplete: Bool
            do {
                (chunk, isComplete) = try await connection.receiveChunk(maximumLength: Self.receiveBufferSize)
            } catch {
                if state != .stopped {
                    Logger.server.error("Receive failed connection=\(self.connectionID): \(error)")
                    messageContinuation.finish(throwing: MCPError.transportError(error))
                    await disconnect()
                }
                return
            }

            // Frames arrive in wire order, which is what keeps verification
            // ahead of the client's initialize when both land in one read.
            for frame in scanner.consume(chunk) {
                switch frame {
                case .authResponse(let response):
                    if let challenge = authChallenge, let handler = onAuthResponse {
                        // Await inline. The CLI sends its auth response ahead
                        // of the client's initialize, and both can land in one
                        // read. Verification has to be recorded before that
                        // initialize reaches the SDK, or an already-paired
                        // client races into the manual approval prompt.
                        await handler(challenge, response)
                        // One-shot: further AUTH-RESPONSE frames on this
                        // connection cannot rewrite the fingerprint or redeem
                        // a pairing code after settle.
                        authChallenge = nil
                    }
                case .message(let message):
                    messageContinuation.yield(message)
                case .authChallenge:
                    break  // Only the app sends challenges.
                }
            }

            switch scanner.disconnectReason {
            case .messageTooLarge:
                let limit = WireContract.maxClientMessageDescription
                Logger.server.error("Client message exceeded \(limit), closing connection=\(self.connectionID)")
                messageContinuation.finish(throwing: MCPError.transportError(POSIXError(.ENOBUFS)))
                await disconnect()
                return
            case .invalidAuthFrame:
                await disconnect()
                return
            case nil:
                break
            }

            if isComplete {
                // A clean close from the CLI half-closes the socket, and a
                // half-closed NWConnection stays `.ready`: only this read
                // sees it. Finishing the stream alone would leave the socket
                // in CLOSE_WAIT.
                Logger.server.debug("Peer closed connection=\(self.connectionID)")
                await disconnect()
                return
            }
        }

        messageContinuation.finish()
    }

    private func sendBytes(_ data: Data) async throws {
        guard state == .connected else {
            throw MCPError.internalError("Transport not connected")
        }

        do {
            try await connection.sendAll(data)
        } catch {
            throw MCPError.transportError(error)
        }
    }
}
