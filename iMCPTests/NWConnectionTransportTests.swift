import CryptoKit
import Network
import XCTest

@testable import iMCP

final class NWConnectionTransportTests: XCTestCase {
    private var client: NWConnection?
    private var transport: NWConnectionTransport?

    override func tearDown() async throws {
        await transport?.disconnect()
        client?.cancel()
        transport = nil
        client = nil
    }

    /// Fails the test instead of hanging forever if an operation never completes.
    private static let testDeadline: Duration = .seconds(5)

    // MARK: - Setup helpers

    private func makeConnectedPair(
        connectionID: UUID = UUID(),
        onClose: @escaping @Sendable () async -> Void = {}
    ) async throws -> (
        transport: NWConnectionTransport, client: NWConnection, connectionID: UUID
    ) {
        let pair = try await LoopbackSocketPair.open(
            queue: DispatchQueue(label: "NWConnectionTransportTests"),
            deadline: Self.testDeadline
        )
        client = pair.client

        let transport = NWConnectionTransport(connection: pair.appEnd, connectionID: connectionID, onClose: onClose)
        self.transport = transport
        try await transport.connect()

        return (transport, pair.client, connectionID)
    }

    private func clientSend(_ client: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Swift.Error>) in
            client.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func clientReceive(_ client: NWConnection, count: Int) async throws -> Data {
        var received = Data()
        while received.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                client.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                    data,
                    _,
                    isComplete,
                    error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: NWError.posix(.ECONNRESET))
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            received.append(chunk)
        }
        return received
    }

    /// The SDK `NetworkTransport.Heartbeat` wire format: four magic bytes
    /// followed by a little-endian millisecond timestamp, no newline.
    private static func heartbeatFrame() -> Data {
        var frame = Data([0xF0, 0x9F, 0x92, 0x93])
        let timestamp = UInt64(Date().timeIntervalSinceReferenceDate * 1000)
        withUnsafeBytes(of: timestamp) { frame.append(contentsOf: $0) }
        return frame
    }

    // MARK: - Framing

    func testYieldsEachNewlineDelimitedMessage() async throws {
        let (transport, client, _) = try await makeConnectedPair()

        try await clientSend(client, Data("{\"a\":1}\n{\"b\":2}\n".utf8))

        let messages = try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) {
            var messages: [Data] = []
            for try await message in await transport.receive() {
                messages.append(message)
                if messages.count == 2 { break }
            }
            return messages
        }

        XCTAssertEqual(String(decoding: messages[0], as: UTF8.self), "{\"a\":1}")
        XCTAssertEqual(String(decoding: messages[1], as: UTF8.self), "{\"b\":2}")
    }

    func testSendAppendsNewlineDelimiter() async throws {
        let (transport, client, _) = try await makeConnectedPair()

        // Drain the auth challenge the transport sends on connect, so the byte
        // count below covers the payload and nothing else.
        _ = try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) { [self] in
            try await clientReceive(client, count: AuthPreamble.challengeFrameLength)
        }

        let payload = Data("{\"result\":\"ok\"}".utf8)
        try await transport.send(payload)

        let received = try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) { [self] in
            try await clientReceive(client, count: payload.count + 1)
        }

        XCTAssertEqual(received, payload + Data("\n".utf8))
    }

    func testCoalescedHeartbeatAndMessageInOneWrite() async throws {
        let (transport, client, _) = try await makeConnectedPair()

        // Heartbeat and message go out in a single write, so they arrive in one
        // TCP read. The message must survive the heartbeat stripping.
        try await clientSend(
            client,
            Self.heartbeatFrame() + Data("{\"coalesced\":true}\n".utf8)
        )

        let message = try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) {
            for try await message in await transport.receive() {
                return message
            }
            throw NWError.posix(.ECONNRESET)
        }

        XCTAssertEqual(String(decoding: message, as: UTF8.self), "{\"coalesced\":true}")
    }

    func testSendsAuthChallengeOnConnect() async throws {
        let connectionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        let (_, client, _) = try await makeConnectedPair(connectionID: connectionID)

        let received = try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) { [self] in
            try await clientReceive(client, count: AuthPreamble.challengeFrameLength)
        }

        let challenge = try XCTUnwrap(AuthChallengeFrame.parse(received).frame)
        XCTAssertEqual(challenge.connectionID, connectionID)
        XCTAssertEqual(challenge.nonce.count, AuthPreamble.nonceLength)
    }

    func testStripsAuthResponseBeforeMCPMessages() async throws {
        let connectionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        let (transport, client, _) = try await makeConnectedPair(connectionID: connectionID)

        let receivedChallenge = try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) {
            [self] in
            try await clientReceive(client, count: AuthPreamble.challengeFrameLength)
        }
        let challenge = try XCTUnwrap(AuthChallengeFrame.parse(receivedChallenge).frame)

        let privateKey = P256.Signing.PrivateKey()
        let response = try AuthResponseFrame.sign(challenge: challenge, privateKey: privateKey)
        try await clientSend(client, response.encode() + Data("{\"auth\":\"ok\"}\n".utf8))

        let message = try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) {
            for try await message in await transport.receive() {
                return message
            }
            throw NWError.posix(.ECONNRESET)
        }

        XCTAssertEqual(String(decoding: message, as: UTF8.self), "{\"auth\":\"ok\"}")
    }

    func testRejectsOutOfRangePairingCodeLengthWithoutScanningLeftoverMCP() async throws {
        let connectionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
        let (transport, client, _) = try await makeConnectedPair(connectionID: connectionID)

        let receivedChallenge = try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) {
            [self] in
            try await clientReceive(client, count: AuthPreamble.challengeFrameLength)
        }
        let challenge = try XCTUnwrap(AuthChallengeFrame.parse(receivedChallenge).frame)
        let response = try AuthResponseFrame.sign(
            challenge: challenge,
            privateKey: P256.Signing.PrivateKey()
        )

        var wire = response.encode()
        wire.append(20)
        wire.append(Data(repeating: 0x41, count: 20))
        try await clientSend(client, wire + Data("{\"leftover\":true}\n".utf8))

        let messages = try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) {
            var messages: [Data] = []
            do {
                for try await message in await transport.receive() {
                    messages.append(message)
                }
            } catch {}
            return messages
        }

        XCTAssertTrue(messages.isEmpty, "leftover MCP must not be scanned after a bad pairing length")
    }

    func testRejectsInvalidUTF8PairingCodeWithoutScanningLeftoverMCP() async throws {
        let connectionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C4")!
        let (transport, client, _) = try await makeConnectedPair(connectionID: connectionID)

        let receivedChallenge = try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) {
            [self] in
            try await clientReceive(client, count: AuthPreamble.challengeFrameLength)
        }
        let challenge = try XCTUnwrap(AuthChallengeFrame.parse(receivedChallenge).frame)
        let response = try AuthResponseFrame.sign(
            challenge: challenge,
            privateKey: P256.Signing.PrivateKey()
        )

        var wire = response.encode()
        wire.append(6)
        wire.append(Data(repeating: 0xFF, count: 6))
        try await clientSend(client, wire + Data("{\"leftover\":true}\n".utf8))

        let messages = try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) {
            var messages: [Data] = []
            do {
                for try await message in await transport.receive() {
                    messages.append(message)
                }
            } catch {}
            return messages
        }

        XCTAssertTrue(messages.isEmpty, "leftover MCP must not be scanned after an invalid pairing code")
    }

    // MARK: - Lifecycle

    func testPeerCloseFinishesReceiveStream() async throws {
        let (transport, client, _) = try await makeConnectedPair()

        client.cancel()

        // The stream must end promptly. Finishing normally and throwing a
        // transport error are both fine. Hanging is the failure mode.
        try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) {
            do {
                for try await _ in await transport.receive() {}
            } catch {}
        }
    }

    func testPeerCloseCancelsTheConnection() async throws {
        let (transport, client, _) = try await makeConnectedPair()

        // Half-close: the peer sends FIN but still reads, so writes to it
        // succeed unless the transport itself cancelled the connection.
        client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) {
            do {
                for try await _ in await transport.receive() {}
            } catch {}
        }

        // A half-closed socket must not stay open behind a finished stream:
        // the session is only reclaimed once the connection is cancelled.
        do {
            try await transport.send(Data("{}".utf8))
            XCTFail("send after peer close should throw because the connection was cancelled")
        } catch {}
    }

    /// The owner learns of a close from the transport itself, once, whichever
    /// end closed.
    func testPeerCloseIsReportedOnce() async throws {
        let closes = Counter()
        let closed = AsyncGate()
        await closed.open()
        let (transport, client, _) = try await makeConnectedPair(onClose: {
            closes.increment()
            await closed.wait()
        })

        client.cancel()
        try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) {
            await closed.waitUntilWaiting(count: 1)
        }
        await transport.disconnect()
        XCTAssertEqual(closes.value, 1)
    }

    func testDisconnectIsReportedOnce() async throws {
        let closes = Counter()
        let (transport, _, _) = try await makeConnectedPair(onClose: { closes.increment() })

        await transport.disconnect()
        await transport.disconnect()

        XCTAssertEqual(closes.value, 1)
    }

    func testDisconnectIsIdempotentAndStopsSends() async throws {
        let (transport, _, _) = try await makeConnectedPair()

        await transport.disconnect()
        await transport.disconnect()

        do {
            try await transport.send(Data("{}".utf8))
            XCTFail("send after disconnect should throw")
        } catch {}
    }

    func testConnectTwiceThrows() async throws {
        let (transport, _, _) = try await makeConnectedPair()

        do {
            try await transport.connect()
            XCTFail("second connect should throw")
        } catch {}
    }

    func testConnectFailureThrows() async throws {
        let queue = DispatchQueue(label: "NWConnectionTransportTests.failure")
        let listener = try NWListener(using: WireContract.loopbackParameters())
        // The listener exists only to reserve a port; it never accepts.
        listener.newConnectionHandler = { $0.cancel() }

        let port = try await listener.startUntilReady(queue: queue)

        // Release the port so the connection attempt below is refused.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                if case .cancelled = state, once.claim() {
                    continuation.resume()
                }
            }
            listener.cancel()
        }

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: WireContract.loopbackParameters()
        )
        let transport = NWConnectionTransport(connection: connection, connectionID: UUID())
        self.transport = transport

        // A refused loopback connect can park NWConnection in .waiting
        // (the framework retries) instead of .failed; cancel after a beat
        // so the attempt reaches a terminal state either way.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(1))
            connection.cancel()
        }
        defer { watchdog.cancel() }

        do {
            try await transport.connect()
            XCTFail("connect to a closed port should throw")
        } catch {}
    }

    func testOverflowDisconnectsConnection() async throws {
        let (transport, client, _) = try await makeConnectedPair()

        try await clientSend(client, Data(repeating: 0x41, count: 1_048_576 + 1))

        try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) {
            do {
                for try await _ in await transport.receive() {}
            } catch {}
        }

        do {
            try await transport.send(Data("{}".utf8))
            XCTFail("send after overflow should throw because disconnect() cancelled the connection")
        } catch {}
    }

    func testDisconnectDuringConnectStopsTransport() async throws {
        // Loopback-restricted parameters to a non-loopback address park the
        // connection in .waiting, so connect() is reliably still in flight
        // when disconnect() runs.
        let connection = NWConnection(
            host: NWEndpoint.Host("203.0.113.1"),
            port: 9,
            using: WireContract.loopbackParameters()
        )
        let transport = NWConnectionTransport(connection: connection, connectionID: UUID())
        self.transport = transport

        let connectTask = Task { try await transport.connect() }
        try await Task.sleep(for: .milliseconds(50))
        await transport.disconnect()

        // connect() must resolve promptly. Throwing on cancellation and
        // returning through the disconnect-during-connect guard are both fine.
        // Hanging is the failure mode.
        _ = try await withDeadline(Self.testDeadline, throwing: NWError.posix(.ETIMEDOUT)) {
            try? await connectTask.value
        }

        do {
            try await transport.send(Data("{}".utf8))
            XCTFail("send after disconnect should throw")
        } catch {}
    }
}
