import CryptoKit
import Dispatch
import Logging
import MCP
import Network
import SystemPackage

import class Foundation.NSLock
import struct Foundation.Data

private func setNonBlocking(fileDescriptor: FileDescriptor) throws {
    let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
    guard flags >= 0 else {
        throw MCPError.transportError(Errno.badFileDescriptor)
    }
    let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
    guard result >= 0 else {
        throw MCPError.transportError(Errno.badFileDescriptor)
    }
}

/// Records that bytes left fd 0 at the moment they do, and lets the recovery
/// decision stop further reads in the same step.
///
/// Bytes taken off stdin cannot be replayed into a new connection. The read
/// happens on a dispatch queue and the decision on an actor, so the two share
/// a lock: a read is either counted before the decision or never happens.
final class StdinReadLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var hasRead = false
    private var isSealed = false

    func read(_ read: () throws -> Int) rethrows -> Int? {
        try lock.withLock {
            guard !isSealed else { return nil }
            let bytesRead = try read()
            if bytesRead > 0 { hasRead = true }
            return bytesRead
        }
    }

    func seal() -> Bool {
        lock.withLock {
            isSealed = true
            return hasRead
        }
    }
}

/// Internal rather than private so CLITests can read from a pipe.
func stdinStream(
    from stdin: FileDescriptor,
    bufferSize: Int,
    latch: StdinReadLatch
) throws -> AsyncThrowingStream<Data, Error> {
    try setNonBlocking(fileDescriptor: stdin)

    return AsyncThrowingStream { continuation in
        let source = DispatchSource.makeReadSource(
            fileDescriptor: stdin.rawValue,
            queue: DispatchQueue.global(qos: .userInitiated)
        )

        var buffer = [UInt8](repeating: 0, count: bufferSize)
        source.setEventHandler {
            do {
                while true {
                    let read = try latch.read {
                        try buffer.withUnsafeMutableBufferPointer { pointer in
                            try stdin.read(into: UnsafeMutableRawBufferPointer(pointer))
                        }
                    }

                    // Sealed: the bytes stay on fd 0 for whoever reads next.
                    guard let bytesRead = read, bytesRead > 0 else {
                        continuation.finish()
                        source.cancel()
                        return
                    }

                    continuation.yield(Data(buffer[..<bytesRead]))

                    guard bytesRead == bufferSize else {
                        return
                    }
                }
            } catch {
                if let posixError = error as? Errno, posixError == .wouldBlock {
                    return
                }

                continuation.finish(throwing: error)
                source.cancel()
            }
        }

        continuation.onTermination = { _ in
            source.cancel()
        }
        source.resume()
    }
}

actor StdioProxy {
    private let endpoint: NWEndpoint
    private let isLoopback: Bool
    private let log: Logger
    private let pairingCode: String?
    private let stdin: FileDescriptor

    private var connection: NWConnection?
    private var isRunning = false

    private var frameScanner = MessageFrameScanner()

    /// The connection delivers its callbacks here rather than on the main queue.
    /// Nothing in the CLI drives a main run loop, so the main queue buys no
    /// ordering the handlers do not already get from a serial queue, and it puts
    /// every state change and every read behind whatever else the process has
    /// scheduled there.
    private let connectionQueue = DispatchQueue(
        label: "me.mattt.iMCP.server.connection"
    )

    /// Stdin waits on this so the signed AUTH-RESPONSE reaches the app before
    /// the client's initialize; a paired client whose initialize arrived
    /// first would be asked about by hand. Opened once the challenge has been
    /// handled, or when other traffic shows the app sends none. The key is
    /// read before the socket opens, so handling the challenge never waits
    /// on the Keychain; `HandshakeDeadline.authResponseWait` bounds the wait
    /// for an app that sends no challenge.
    private let authPreambleSettled = Latch()

    private let stdinLatch = StdinReadLatch()

    /// Stops this proxy reading stdin and reports whether it ever took a byte,
    /// including bytes read but not yet forwarded. Those bytes cannot be
    /// replayed into a new connection, so a proxy that answers `true` is never
    /// replaced.
    nonisolated func sealStdin() -> Bool {
        stdinLatch.seal()
    }

    /// Read once, in `start()`, before connecting.
    private let signingKeyRead: DeadlinedValue<P256.Signing.PrivateKey?>
    private var signingKey: P256.Signing.PrivateKey?

    private static let stdinBufferSize = 256 * 1024
    /// 10 MB, so a single large tool result moves in one read rather than
    /// being reassembled chunk by chunk.
    private static let networkBufferSize = 10 * 1024 * 1024

    /// - Parameters:
    ///   - isLoopback: Whether `endpoint` came from the endpoint file rather
    ///     than Bonjour. Only the failure notice depends on it.
    ///   - pairingCode: Included in the signed auth response, which lets a
    ///     first-run client pair without the approval dialog.
    ///   - stdin: Where client bytes come from. CLITests pass a pipe.
    ///   - readSigningKey: A blocking read of the key that answers the
    ///     challenge. CLITests pass their own.
    init(
        endpoint: NWEndpoint,
        isLoopback: Bool,
        log: Logger,
        pairingCode: String? = nil,
        stdin: FileDescriptor = .standardInput,
        readSigningKey: @escaping @Sendable () -> P256.Signing.PrivateKey? = { ClientKeyStore.loadSigningKey() }
    ) {
        self.endpoint = endpoint
        self.isLoopback = isLoopback
        self.log = log
        self.pairingCode = pairingCode
        self.stdin = stdin
        self.signingKeyRead = DeadlinedValue(readSigningKey)
    }

    func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        // The app's setup deadline starts when it accepts the socket, so the
        // key is read first: a Keychain prompt then delays the connection
        // rather than the answer to the app's challenge.
        signingKey = await resolveSigningKey()
        guard isRunning else { throw CancellationError() }

        let connection = NWConnection(to: endpoint, using: WireContract.loopbackParameters())
        self.connection = connection
        let log = self.log
        let timeoutNotice = CLIBootstrap.connectionTimeoutNotice(isLoopback: isLoopback)

        do {
            try await connection.startUntilReady(queue: connectionQueue, timeout: CLIBootstrap.connectTimeout) {
                [weak self] state in
                Task { await self?.handleConnectionState(state) }
            }
        } catch is NWConnectionReadyTimeout {
            log.error("\(timeoutNotice)")
            throw MCPError.internalError(timeoutNotice)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await self.handleStdinToNetwork()
                } catch {
                    log.error("Stdin handler failed: \(error)")
                    throw error
                }
            }

            group.addTask {
                do {
                    try await self.handleNetworkToStdout()
                } catch {
                    log.error("Network handler failed: \(error)")
                    throw error
                }
            }

            // On the retry paths the NWConnection must be cancelled before a
            // new proxy is created.
            do {
                try await group.next()
                log.debug("A task completed, cancelling remaining tasks")
            } catch {
                group.cancelAll()
                await self.stop()
                throw error
            }

            group.cancelAll()
            await self.stop()
        }
    }

    func stop() async {
        isRunning = false
        connection?.cancel()
        connection = nil
    }

    /// Without a key the challenge goes unanswered, and iMCP treats this
    /// client as unpaired: it asks for approval by hand once the client sends
    /// initialize, and otherwise closes the connection.
    private func resolveSigningKey() async -> P256.Signing.PrivateKey? {
        guard let loaded = await signingKeyRead.value(within: HandshakeDeadline.signingKeyRead) else {
            log.error(
                """
                Timed out after \(HandshakeDeadline.signingKeyRead) reading the signing key. \
                macOS is most likely showing a Keychain authorization prompt for \
                imcp-server that has not been answered; answer it and choose Always \
                Allow, then restart this client. Connecting without the key, so iMCP \
                treats this client as unpaired.
                """
            )
            return nil
        }
        if loaded == nil {
            log.error("No signing key available to answer the auth challenge")
        }
        return loaded
    }

    private func sendRawToNetwork(_ data: Data) async throws {
        guard isRunning, let connection else {
            throw StdioProxyError.connectionClosed
        }

        try await connection.sendAll(data)
    }

    private func handleConnectionState(_ state: NWConnection.State) async {
        switch state {
        case .ready:
            log.debug("Connection established to \(endpoint)")
        case .failed(let error):
            log.debug("Connection failed: \(error)")
            await stop()
        case .cancelled:
            log.debug("Connection cancelled")
            await stop()
        case .waiting(let error):
            log.debug("Connection waiting: \(error)")
        case .preparing:
            log.debug("Connection preparing...")
        case .setup:
            log.debug("Connection setup...")
        @unknown default:
            log.debug("Unknown connection state")
        }
    }

    private func liveConnection(for pump: String) throws -> NWConnection {
        guard isRunning, let connection else {
            log.debug("Connection no longer active, stopping \(pump) handler")
            throw StdioProxyError.connectionClosed
        }
        if connection.state != .ready && connection.state != .preparing {
            log.debug("Connection state changed to \(connection.state), stopping \(pump) handler")
            throw StdioProxyError.connectionClosed
        }
        return connection
    }

    private func handleStdinToNetwork() async throws {
        var stdinFrames = StdinFrameScanner()
        let input = try stdinStream(from: stdin, bufferSize: Self.stdinBufferSize, latch: stdinLatch)
        for try await inputData in input {
            _ = try liveConnection(for: "stdin")

            for frame in try stdinFrames.consume(inputData) {
                await authPreambleSettled.wait(within: HandshakeDeadline.authResponseWait)
                try Task.checkCancellation()
                try await sendRawToNetwork(frame)
                log.debug("Sent \(frame.count) bytes to network")
            }
        }

        // Stdin EOF means the MCP client hung up, and that has to be terminal.
        // Returning normally here would send MCPService.run() back into
        // discovery, reconnecting (and re-prompting for approval) forever.
        log.debug("Stdin closed (EOF), stopping stdin handler")
        throw StdioProxyError.stdinClosed
    }

    /// Internal rather than private so CLITests can drive a chunk without a
    /// socket.
    func handleNetworkChunk(_ data: Data, isComplete: Bool, stdout: FileDescriptor) async throws {
        if !data.isEmpty {
            var messages: [Data] = []
            var challenges: [AuthChallengeFrame] = []
            for frame in frameScanner.consume(data) {
                switch frame {
                case .message(let message): messages.append(message)
                case .authChallenge(let challenge): challenges.append(challenge)
                case .authResponse: break  // Only the CLI sends these.
                }
            }
            for challenge in challenges {
                guard let signingKey else {
                    log.notice("Leaving the auth challenge unanswered: no signing key")
                    continue
                }
                let response: AuthResponseFrame
                do {
                    response = try AuthResponseFrame.sign(
                        challenge: challenge,
                        privateKey: signingKey,
                        pairingCode: pairingCode
                    )
                } catch {
                    log.error("Failed to sign auth response: \(error)")
                    continue
                }
                try await self.sendRawToNetwork(response.encode())
                log.debug("Sent auth response for connection \(challenge.connectionID)")
            }
            if !challenges.isEmpty || !messages.isEmpty {
                await authPreambleSettled.open()
            }

            if !messages.isEmpty {
                log.debug("Received \(messages.count) complete message(s) from network")
            }

            // Stdout is left blocking (only stdin is made non-blocking), so
            // `writeAll` finishes a partial write, EINTR included.
            for message in messages {
                _ = try stdout.writeAll(MessageFrameScanner.frame(message))
            }
        }

        if isComplete {
            log.debug("Network connection complete")
            throw StdioProxyError.connectionClosed
        }
    }

    private func handleNetworkToStdout() async throws {
        let stdout = FileDescriptor.standardOutput

        while true {
            let connection = try liveConnection(for: "network")

            // No idle deadline. The app is on loopback, so a peer that goes
            // away closes the socket, and the read ends. A timeout could only
            // reconnect, and a reconnected session is one the app never
            // approved and the client never initialized: every later call
            // fails "not approved" until the client restarts. A client that
            // was simply quiet for a while is not a failure.
            do {
                let (data, isComplete) = try await connection.receiveChunk(maximumLength: Self.networkBufferSize)
                try await handleNetworkChunk(data, isComplete: isComplete, stdout: stdout)
            } catch {
                if let closed = StdioProxyError(networkReadFailure: error) {
                    log.debug("Connection closed by peer: \(error)")
                    throw closed
                }
                if error is StdioProxyError {
                    throw error
                }
                log.error("Error in network handler: \(error)")
                throw error
            }
        }
    }
}
