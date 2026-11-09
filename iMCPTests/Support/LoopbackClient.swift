import CryptoKit
import Foundation
import MCP
import Network
import XCTest

@testable import iMCP

/// The CLI's side of one connection to a `ServerNetworkManager`, over a real
/// loopback socket whose app end goes through `accept` like any other: it
/// reads the challenge, sends an AUTH-RESPONSE, and exchanges JSON-RPC lines.
final class LoopbackClient: @unchecked Sendable {
    /// Fails the test instead of hanging if the app never answers.
    static let deadline: Duration = .seconds(5)

    private let connection: NWConnection
    private var buffer = Data()
    private var nextID = 1
    private(set) var challenge: AuthChallengeFrame?

    private init(connection: NWConnection) {
        self.connection = connection
    }

    /// Connects a socket and hands its app end to `manager`.
    static func connect(to manager: ServerNetworkManager) async throws -> LoopbackClient {
        let pair = try await LoopbackSocketPair.open(queue: DispatchQueue(label: "LoopbackClient"), deadline: deadline)
        await manager.accept(pair.appEnd)
        return LoopbackClient(connection: pair.client)
    }

    /// Reads the challenge and answers it, signed with `key`. `signedChallenge`
    /// signs a different challenge instead, so the signature does not verify.
    func authenticate(
        with key: P256.Signing.PrivateKey,
        pairingCode: String? = nil,
        signing signedChallenge: AuthChallengeFrame? = nil
    ) async throws {
        let challenge = try await readChallenge()
        let response = try AuthResponseFrame.sign(
            challenge: signedChallenge ?? challenge,
            privateKey: key,
            pairingCode: pairingCode
        )
        try await send(response.encode())
    }

    func readChallenge() async throws -> AuthChallengeFrame {
        let bytes = try await read(count: AuthPreamble.challengeFrameLength)
        let frame = try XCTUnwrap(AuthChallengeFrame.parse(bytes).frame)
        challenge = frame
        return frame
    }

    /// Sends one request and returns the reply's `result`, or throws its error message.
    @discardableResult
    func request(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        try await send(JSONSerialization.data(withJSONObject: message) + Data("\n".utf8))
        let reply = try await readLine()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        if let error = object["error"] as? [String: Any] {
            throw ReplyError(message: error["message"] as? String ?? "")
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    @discardableResult
    func initialize(clientName: String = "test-client") async throws -> [String: Any] {
        try await request(
            "initialize",
            params: [
                "protocolVersion": Version.latest,
                "capabilities": [String: Any](),
                "clientInfo": ["name": clientName, "version": "1"],
            ]
        )
    }

    func send(_ data: Data) async throws {
        try await withDeadline(Self.deadline, throwing: NWError.posix(.ETIMEDOUT)) {
            try await self.connection.sendAll(data)
        }
    }

    /// Returns once the app has closed its end.
    func waitForClose() async throws {
        try await withDeadline(Self.deadline, throwing: NWError.posix(.ETIMEDOUT)) {
            while (try? await self.receiveChunk()) != nil {}
        }
    }

    func close() {
        connection.cancel()
    }

    struct ReplyError: Error, Equatable {
        let message: String
    }

    struct Closed: Error {}

    private func readLine() async throws -> Data {
        try await withDeadline(Self.deadline, throwing: NWError.posix(.ETIMEDOUT)) {
            while true {
                if let newline = self.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = self.buffer[..<newline]
                    self.buffer.removeSubrange(...newline)
                    return Data(line)
                }
                self.buffer.append(try await self.receiveChunk())
            }
        }
    }

    private func read(count: Int) async throws -> Data {
        try await withDeadline(Self.deadline, throwing: NWError.posix(.ETIMEDOUT)) {
            while self.buffer.count < count {
                self.buffer.append(try await self.receiveChunk())
            }
            let bytes = self.buffer.prefix(count)
            self.buffer.removeFirst(count)
            return Data(bytes)
        }
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: Closed())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

/// An approval prompt that records what it was asked, holds each request at
/// `gate` when there is one, and gives `answer`. A cancelled ask is `.denied`.
actor ApprovalPromptRecorder {
    private(set) var requests: [ConnectionApprovalRequest] = []
    private(set) var cancelledCount = 0
    private let gate: AsyncGate?
    private let answer: ApprovalAnswer
    private let cancellations = CountLatch()

    init(answer: ApprovalAnswer = .approved(pair: false), gate: AsyncGate? = nil) {
        self.answer = answer
        self.gate = gate
    }

    nonisolated var prompt: ApprovalPrompt {
        { request in await self.ask(request) }
    }

    func ask(_ request: ConnectionApprovalRequest) async -> ApprovalAnswer {
        requests.append(request)
        await gate?.wait()
        guard !Task.isCancelled else {
            cancelledCount += 1
            await cancellations.reach(cancelledCount)
            return .denied
        }
        return answer
    }

    /// Returns once `count` asks have been cancelled, or fails the test after
    /// `CountLatch.deadline`.
    func waitForCancellations(count: Int = 1, file: StaticString = #filePath, line: UInt = #line) async {
        await cancellations.wait(count: count, what: "asks were cancelled", file: file, line: line)
    }
}

extension XCTestCase {
    /// A manager that never listens, so connections reach it only through
    /// `accept`, and never writes the endpoint file.
    @MainActor
    func makeServerNetworkManager(
        storage: PairedClientStorage,
        pairingCodes: PairingCodeIssuer = PairingCodeIssuer(),
        clock: WallClock = .live,
        pairedLookup: Duration = HandshakeDeadline.pairedLookup,
        prompt: @escaping ApprovalPrompt
    ) -> ServerNetworkManager {
        makeServerNetworkManager(
            pairedClients: PairedClientStore(storage: storage),
            pairingCodes: pairingCodes,
            clock: clock,
            pairedLookup: pairedLookup,
            prompt: prompt
        )
    }

    @MainActor
    func makeServerNetworkManager(
        pairedClients: PairedClientStore,
        pairingCodes: PairingCodeIssuer = PairingCodeIssuer(),
        clock: WallClock = .live,
        pairedLookup: Duration = HandshakeDeadline.pairedLookup,
        prompt: @escaping ApprovalPrompt
    ) -> ServerNetworkManager {
        ServerNetworkManager(
            listener: nil,
            pairedClients: pairedClients,
            pairingCodes: pairingCodes,
            entries: [],
            clock: clock,
            pairedLookup: pairedLookup,
            prompt: prompt
        )
    }
}
