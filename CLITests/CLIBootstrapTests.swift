import CryptoKit
import Foundation
import Logging
import MCP
import Security
import Network
import SystemPackage
import XCTest
import os

private let testLog = Logger(label: "imcp-serverTests")

final class CLIBootstrapTests: XCTestCase {
    func testResolvedPairingCodeFromArguments() {
        XCTAssertEqual(
            CLIBootstrap.resolvedPairingCode(from: ["imcp-server", "--pair", "ABCD23"]),
            "ABCD23"
        )
    }

    func testResolvedPairingCodeFromEnvironment() {
        let key = PairingCode.environmentVariable
        setenv(key, "ENV4567", 1)
        defer { unsetenv(key) }

        XCTAssertEqual(
            CLIBootstrap.resolvedPairingCode(from: ["imcp-server"]),
            "ENV4567"
        )
    }

    /// Previously `IMCP_PAIR_CODE` silently won when `--pair` also appeared.
    /// Agreeing sources must resolve to that shared value.
    func testResolvedPairingCodeWhenFlagAndEnvironmentAgree() {
        let key = PairingCode.environmentVariable
        setenv(key, "ABCD23", 1)
        defer { unsetenv(key) }

        XCTAssertEqual(
            CLIBootstrap.resolvedPairingCode(from: ["imcp-server", "--pair", "ABCD23"]),
            "ABCD23"
        )
        XCTAssertEqual(
            CLIBootstrap.pairingCodeResolution(environmentCode: "abcd23", argumentCode: "ABCD23"),
            .value("ABCD23")
        )
    }

    /// Previously `IMCP_PAIR_CODE` silently won when `--pair` also appeared.
    /// Disagreeing sources must fail closed instead of preferring env.
    func testPairingCodeResolutionConflictsWhenFlagAndEnvironmentDisagree() {
        XCTAssertEqual(
            CLIBootstrap.pairingCodeResolution(environmentCode: "ENV4567", argumentCode: "ABCD23"),
            .conflict
        )
    }

    func testDiscoveryReturnsToLoopbackAfterBonjourFailure() {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 57744)
        XCTAssertEqual(ResolvedEndpoint.loopback(endpoint).discoveryModeAfterFailure, .bonjourOnly)
        XCTAssertEqual(ResolvedEndpoint.bonjour(endpoint).discoveryModeAfterFailure, .preferLoopback)
    }

    func testAHandoffWithNoServicesOnSaysSo() {
        XCTAssertEqual(
            CLIBootstrap.zeroServicesNotice(
                for: ListenerEndpointFile.Contents(port: 57744, pid: 4242, enabledServices: [])
            ),
            "iMCP is running, but no services are on. Turn one on in the menu bar."
        )
    }

    func testOnlyAUsableHandoffResolvesToALoopbackEndpoint() {
        let contents = ListenerEndpointFile.Contents(port: 57744, pid: 4242)
        XCTAssertEqual(
            ResolvedEndpoint(loopback: .usable(contents)),
            .loopback(.hostPort(host: "127.0.0.1", port: 57744))
        )
        XCTAssertNil(ResolvedEndpoint(loopback: .missing))
        XCTAssertNil(ResolvedEndpoint(loopback: .processDead(pid: 9)))
    }

    func testInspectionNoticesTellTheUserWhatToDo() {
        XCTAssertEqual(
            CLIBootstrap.userNotice(for: .missing),
            "iMCP is not running. Open iMCP from the menu bar."
        )
        XCTAssertEqual(
            CLIBootstrap.userNotice(for: .processDead(pid: 4242)),
            "iMCP is not running. The last session quit. Open iMCP from the menu bar."
        )
    }

    func testZeroServicesNoticeOnlyForAnEmptyServiceList() {
        XCTAssertNil(
            CLIBootstrap.zeroServicesNotice(
                for: .init(port: 57744, pid: 4242, enabledServices: ["Messages", "Utilities"])
            )
        )
        XCTAssertNil(CLIBootstrap.zeroServicesNotice(for: .init(port: 57744, pid: 4242)))
        XCTAssertEqual(
            CLIBootstrap.zeroServicesNotice(for: .init(port: 57744, pid: 4242, enabledServices: [])),
            "iMCP is running, but no services are on. Turn one on in the menu bar."
        )
    }

    func testConnectionTimeoutNoticeNamesLoopbackWithoutLocalNetwork() {
        let loopback = CLIBootstrap.connectionTimeoutNotice(isLoopback: true)
        XCTAssertTrue(loopback.contains("Open iMCP from the menu bar"))
        XCTAssertFalse(loopback.contains("Local Network"))

        let bonjour = CLIBootstrap.connectionTimeoutNotice(isLoopback: false)
        XCTAssertTrue(bonjour.contains("Local Network"))
    }

    func testBonjourTimeoutNoticeKeepsLoopbackAutopsy() {
        let notice = CLIBootstrap.bonjourTimeoutNotice(loopbackInspection: .missing)
        XCTAssertTrue(notice.contains("iMCP is not running"))
        XCTAssertTrue(notice.contains("Local Network"))
    }

    func testCLIParametersRequireLoopback() {
        let parameters = WireContract.loopbackParameters()
        XCTAssertEqual(parameters.requiredInterfaceType, .loopback)
        XCTAssertTrue(parameters.acceptLocalOnly)
        XCTAssertFalse(parameters.includePeerToPeer)
        let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options
        XCTAssertEqual(ip?.version, .v4)
    }

    func testFingerprintMatchesAuthPreambleDerivation() throws {
        let privateKey = P256.Signing.PrivateKey()
        let expected = AuthPreamble.clientPublicKeyFingerprint(from: privateKey.publicKey)
        let actual = ClientKeyStore.publicKeyFingerprint(for: privateKey)
        XCTAssertEqual(actual, expected)
    }

    /// Rotation has to be visible to the app, which trusts clients by public-key
    /// fingerprint. If the old key still verified against the new fingerprint,
    /// `--rotate-key` would not actually revoke anything.
    func testRotateKeyChangesFingerprintAndInvalidatesOldKey() throws {
        let keyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("imcp-test-key-\(UUID().uuidString).dat")
            .path
        setenv(ClientKeyStore.keyFileEnvironmentVariable, keyPath, 1)
        defer {
            unsetenv(ClientKeyStore.keyFileEnvironmentVariable)
            try? FileManager.default.removeItem(atPath: keyPath)
        }

        let originalKey = try XCTUnwrap(ClientKeyStore.loadSigningKey())
        let originalFingerprint = ClientKeyStore.publicKeyFingerprint(for: originalKey)

        let rotation = try XCTUnwrap(ClientKeyStore.rotateSigningKey())
        XCTAssertEqual(rotation.oldFingerprint, originalFingerprint)
        XCTAssertNotEqual(rotation.newFingerprint, originalFingerprint)

        let loadedKey = try XCTUnwrap(ClientKeyStore.loadSigningKey())
        XCTAssertEqual(ClientKeyStore.publicKeyFingerprint(for: loadedKey), rotation.newFingerprint)

        let challenge = AuthChallengeFrame(connectionID: UUID())
        let oldResponse = try AuthResponseFrame.sign(challenge: challenge, privateKey: originalKey)
        XCTAssertEqual(
            AuthResponseFrame.verifiedFingerprint(response: oldResponse, challenge: challenge),
            rotation.oldFingerprint
        )
        XCTAssertNotEqual(
            AuthResponseFrame.verifiedFingerprint(response: oldResponse, challenge: challenge),
            rotation.newFingerprint
        )

        let newResponse = try AuthResponseFrame.sign(challenge: challenge, privateKey: loadedKey)
        XCTAssertEqual(
            AuthResponseFrame.verifiedFingerprint(response: newResponse, challenge: challenge),
            rotation.newFingerprint
        )
    }

    func testMissingKeyFileCreatesAndPersistsAKey() throws {
        let keyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("imcp-test-key-\(UUID().uuidString).dat")
            .path
        setenv(ClientKeyStore.keyFileEnvironmentVariable, keyPath, 1)
        defer {
            unsetenv(ClientKeyStore.keyFileEnvironmentVariable)
            try? FileManager.default.removeItem(atPath: keyPath)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: keyPath))

        let key = try XCTUnwrap(ClientKeyStore.loadSigningKey())

        XCTAssertTrue(FileManager.default.fileExists(atPath: keyPath))
        let persisted = try XCTUnwrap(FileManager.default.contents(atPath: keyPath))
        XCTAssertEqual(persisted, key.rawRepresentation)
    }

    /// A corrupt or unreadable key file must never be overwritten. Silently
    /// regenerating it unpairs the client with no explanation, since the app
    /// trusts by public-key fingerprint.
    func testCorruptKeyFileIsNotOverwritten() throws {
        let keyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("imcp-test-key-\(UUID().uuidString).dat")
            .path
        let garbage = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        try garbage.write(to: URL(fileURLWithPath: keyPath))

        setenv(ClientKeyStore.keyFileEnvironmentVariable, keyPath, 1)
        defer {
            unsetenv(ClientKeyStore.keyFileEnvironmentVariable)
            try? FileManager.default.removeItem(atPath: keyPath)
        }

        let loaded = ClientKeyStore.loadSigningKey()
        XCTAssertNil(loaded)

        let contentsAfter = try XCTUnwrap(FileManager.default.contents(atPath: keyPath))
        XCTAssertEqual(contentsAfter, garbage)
    }

    func testValidKeyFileRoundTrips() throws {
        let keyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("imcp-test-key-\(UUID().uuidString).dat")
            .path
        let originalKey = P256.Signing.PrivateKey()
        try originalKey.rawRepresentation.write(to: URL(fileURLWithPath: keyPath))

        setenv(ClientKeyStore.keyFileEnvironmentVariable, keyPath, 1)
        defer {
            unsetenv(ClientKeyStore.keyFileEnvironmentVariable)
            try? FileManager.default.removeItem(atPath: keyPath)
        }

        let loadedKey = try XCTUnwrap(ClientKeyStore.loadSigningKey())
        XCTAssertEqual(
            ClientKeyStore.publicKeyFingerprint(for: loadedKey),
            ClientKeyStore.publicKeyFingerprint(for: originalKey)
        )
    }

    /// A Keychain held in memory that counts writes, so a test can tell a
    /// key that was made from one that was found.
    private final class FakeKeychain: Sendable {
        private let state: OSAllocatedUnfairLock<(stored: KeychainItem.LoadResult, saves: Int, deletes: Int)>

        init(_ stored: KeychainItem.LoadResult) {
            state = OSAllocatedUnfairLock(initialState: (stored, 0, 0))
        }

        var stored: KeychainItem.LoadResult { state.withLock { $0.stored } }
        var saves: Int { state.withLock { $0.saves } }
        var deletes: Int { state.withLock { $0.deletes } }

        var keychain: KeychainItemCalls {
            KeychainItemCalls(
                load: { self.state.withLock { $0.stored } },
                save: { data in
                    self.state.withLock {
                        $0.saves += 1
                        $0.stored = .data(data)
                    }
                    return true
                },
                delete: {
                    self.state.withLock {
                        $0.deletes += 1
                        $0.stored = .missing
                    }
                    return true
                }
            )
        }
    }

    /// A Keychain that could not be read (locked, or a prompt nobody could
    /// answer) still holds the paired key. Making a new one there would turn
    /// a paired client into an unknown one, so nothing is written and there
    /// is no key to sign with.
    func testAnUnreadableKeychainKeyIsNeverReplaced() {
        let fake = FakeKeychain(.failed(errSecInteractionNotAllowed))

        XCTAssertNil(ClientKeyStore.loadSigningKey(from: .keychain, keychain: fake.keychain))
        XCTAssertNil(ClientKeyStore.rotateSigningKey(at: .keychain, keychain: fake.keychain))

        XCTAssertEqual(fake.saves, 0)
        XCTAssertEqual(fake.deletes, 0)
        XCTAssertEqual(fake.stored, .failed(errSecInteractionNotAllowed))
    }

    /// The Debug carry-over must not start a key file of its own when the
    /// Keychain key it would carry over could not be read.
    func testAnUnreadableKeychainKeyIsNotSupersededByANewKeyFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("imcp-test-key-\(UUID().uuidString).dat")
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeKeychain(.failed(errSecInteractionNotAllowed))

        let location = ClientKeyStore.KeyLocation.file(url, carriesOverKeychainKey: true)
        XCTAssertNil(ClientKeyStore.loadSigningKey(from: location, keychain: fake.keychain))

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(fake.saves, 0)
    }

    func testAKeychainWithNoKeyGetsOneThatIsKept() throws {
        let fake = FakeKeychain(.missing)

        let made = try XCTUnwrap(ClientKeyStore.loadSigningKey(from: .keychain, keychain: fake.keychain))
        let again = try XCTUnwrap(ClientKeyStore.loadSigningKey(from: .keychain, keychain: fake.keychain))

        XCTAssertEqual(fake.saves, 1)
        XCTAssertEqual(made.rawRepresentation, again.rawRepresentation)
    }

    func testTheDebugKeyFileCarriesOverTheKeychainKey() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("imcp-test-key-\(UUID().uuidString).dat")
        defer { try? FileManager.default.removeItem(at: url) }
        let existing = P256.Signing.PrivateKey()
        let fake = FakeKeychain(.data(existing.rawRepresentation))

        let location = ClientKeyStore.KeyLocation.file(url, carriesOverKeychainKey: true)
        let loaded = try XCTUnwrap(ClientKeyStore.loadSigningKey(from: location, keychain: fake.keychain))

        XCTAssertEqual(loaded.rawRepresentation, existing.rawRepresentation)
        XCTAssertEqual(FileManager.default.contents(atPath: url.path), existing.rawRepresentation)
        XCTAssertEqual(fake.saves, 0)
    }

    func testAProxyThatConsumedStdinIsNeverReplaced() {
        let errors: [any Error] = [
            StdioProxyError.connectionClosed,
            StdioProxyError.stdinClosed,
            NWError.posix(.EPIPE),
            NWError.posix(.ECONNRESET),
            CancellationError(),
        ]
        for error in errors {
            XCTAssertEqual(
                CLIBootstrap.recovery(after: error, hasConsumedStdin: true),
                .terminate,
                "\(error)"
            )
        }
    }

    func testPeerCloseBeforeTheClientSpokeReconnects() {
        XCTAssertEqual(
            CLIBootstrap.recovery(after: StdioProxyError.connectionClosed, hasConsumedStdin: false),
            .reconnect
        )
    }

    func testStdinEndingIsTerminalEvenBeforeAnyBytes() {
        XCTAssertEqual(
            CLIBootstrap.recovery(after: StdioProxyError.stdinClosed, hasConsumedStdin: false),
            .terminate
        )
        XCTAssertEqual(
            CLIBootstrap.recovery(after: StdioProxyError.stdinFrameTooLarge, hasConsumedStdin: false),
            .terminate
        )
    }

    /// A reset socket is the app going away, not an unreachable endpoint. This
    /// used to reach recovery as a raw `NWError` and rediscover.
    func testPeerResetBeforeTheClientSpokeReconnects() throws {
        for code in [POSIXErrorCode.ECONNRESET, .ENOTCONN] {
            let mapped = try XCTUnwrap(StdioProxyError(networkReadFailure: NWError.posix(code)))
            XCTAssertEqual(mapped, .connectionClosed)
            XCTAssertEqual(CLIBootstrap.recovery(after: mapped, hasConsumedStdin: false), .reconnect)
            XCTAssertEqual(CLIBootstrap.recovery(after: mapped, hasConsumedStdin: true), .terminate)
        }
        XCTAssertTrue(isClosedSocketError(MCPError.transportError(NWError.posix(.ECONNRESET))))
        XCTAssertNil(StdioProxyError(networkReadFailure: NWError.posix(.ETIMEDOUT)))
        XCTAssertNil(StdioProxyError(networkReadFailure: NWError.posix(.ECONNREFUSED)))
    }

    func testConnectFailureBeforeTheClientSpokeRediscovers() {
        XCTAssertEqual(
            CLIBootstrap.recovery(after: NWError.posix(.ECONNREFUSED), hasConsumedStdin: false),
            .rediscover
        )
    }

    // MARK: - Launching the app

    func testLaunchesTheAppWhenNoneIsRunning() {
        XCTAssertEqual(
            CLIBootstrap.appLaunchDecision(isAppRunning: false, lastRequest: nil, now: Date()),
            .launch
        )
    }

    func testLeavesARunningAppAlone() {
        // A running app means the endpoint file is stale or the connection
        // failed for another reason. Launching again fixes neither.
        XCTAssertEqual(
            CLIBootstrap.appLaunchDecision(isAppRunning: true, lastRequest: nil, now: Date()),
            .alreadyRunning
        )
    }

    func testDoesNotAskTwiceWithinOneDiscoveryCycle() {
        let now = Date()
        XCTAssertEqual(
            CLIBootstrap.appLaunchDecision(
                isAppRunning: false,
                lastRequest: now.addingTimeInterval(-1),
                now: now
            ),
            .coolingDown
        )
    }

    func testAsksAgainAfterTheCooldown() {
        let now = Date()
        XCTAssertEqual(
            CLIBootstrap.appLaunchDecision(
                isAppRunning: false,
                lastRequest: now.addingTimeInterval(-CLIBootstrap.appLaunchRequestCooldown),
                now: now
            ),
            .launch
        )
    }

    func testPairingCodeIsSentOnlyOverLoopback() {
        XCTAssertEqual(CLIBootstrap.pairingCodeDelivery("ABCD23", resolvedViaLoopback: true), .send("ABCD23"))
        XCTAssertEqual(CLIBootstrap.pairingCodeDelivery("ABCD23", resolvedViaLoopback: false), .withheld)
        XCTAssertNil(CLIBootstrap.pairingCodeDelivery("ABCD23", resolvedViaLoopback: false).code)
        XCTAssertEqual(CLIBootstrap.pairingCodeDelivery(nil, resolvedViaLoopback: true), .none)
        XCTAssertEqual(CLIBootstrap.pairingCodeDelivery(nil, resolvedViaLoopback: false), .none)
    }

    /// Attributes only; the key file itself is never read here.
    func testNewKeyFileAndDirectoryAreOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("imcp-test-keydir-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("sub", isDirectory: true)
        let keyPath = directory.appendingPathComponent("client-key").path
        setenv(ClientKeyStore.keyFileEnvironmentVariable, keyPath, 1)
        defer {
            unsetenv(ClientKeyStore.keyFileEnvironmentVariable)
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertNotNil(ClientKeyStore.loadSigningKey())

        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: keyPath)[.posixPermissions] as? NSNumber
        )
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(fileMode.intValue, 0o600)
        XCTAssertEqual(directoryMode.intValue, 0o700)
    }

    /// The CLI's bad-code error states the rule `PairingCode` enforces.
    func testThePairingCodeRuleIsDescribedFromTheAlphabet() {
        XCTAssertEqual(PairingCode.formatDescription, "6-8 chars from A-Z/0-9 (no I/O/0/1)")
        for excluded in ["I", "O", "0", "1"] {
            XCTAssertFalse(PairingCode.isValid("ABCD2" + excluded))
        }
        XCTAssertTrue(PairingCode.isValid("ABCD23"))
    }

    func testANetworkReadEndingWithENODATAIsAClose() {
        XCTAssertEqual(StdioProxyError(networkReadFailure: NWError.posix(.ENODATA)), .connectionClosed)
        XCTAssertNil(StdioProxyError(networkReadFailure: NWError.posix(.ETIMEDOUT)))
    }
}

final class StdioProxyTests: XCTestCase {
    private let reply = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n".utf8)

    /// Never started, so it opens no socket and reads no stdin.
    private func makeProxy() -> StdioProxy {
        StdioProxy(
            endpoint: .hostPort(host: "127.0.0.1", port: 9),
            isLoopback: true,
            log: testLog
        )
    }

    /// Feeds one chunk and returns what reached stdout, plus any error.
    private func deliver(
        _ chunk: Data,
        isComplete: Bool,
        to proxy: StdioProxy
    ) async -> (written: Data, error: (any Error)?) {
        let pipe = Pipe()
        var thrown: (any Error)?
        do {
            try await proxy.handleNetworkChunk(
                chunk,
                isComplete: isComplete,
                stdout: FileDescriptor(rawValue: pipe.fileHandleForWriting.fileDescriptor)
            )
        } catch {
            thrown = error
        }
        try? pipe.fileHandleForWriting.close()
        return (pipe.fileHandleForReading.readDataToEndOfFile(), thrown)
    }

    func testMessageIsWrittenToStdoutWithItsNewline() async {
        let result = await deliver(reply, isComplete: false, to: makeProxy())
        XCTAssertEqual(result.written, reply)
        XCTAssertNil(result.error)
    }

    func testPartialMessageIsHeldUntilItsNewline() async {
        let proxy = makeProxy()
        let first = await deliver(Data(reply.prefix(10)), isComplete: false, to: proxy)
        XCTAssertEqual(first.written, Data())
        let second = await deliver(Data(reply.dropFirst(10)), isComplete: false, to: proxy)
        XCTAssertEqual(second.written, reply)
    }

    /// The app's last reply and its close can arrive in one read. The reply
    /// used to be discarded.
    func testReplyDeliveredWithCloseIsWrittenBeforeTheProxyStops() async {
        let result = await deliver(reply, isComplete: true, to: makeProxy())
        XCTAssertEqual(result.written, reply)
        XCTAssertEqual(result.error as? StdioProxyError, .connectionClosed)
    }

    func testCloseWithNoDataStopsTheProxy() async {
        let result = await deliver(Data(), isComplete: true, to: makeProxy())
        XCTAssertEqual(result.written, Data())
        XCTAssertEqual(result.error as? StdioProxyError, .connectionClosed)
    }
}

/// Runs a real `StdioProxy` against a loopback listener standing in for the
/// app, with a pipe standing in for the client's stdin.
final class StdinRecoveryTests: XCTestCase {
    private enum HangUp {
        case onAccept
        case afterFirstBytes
        /// Sends a challenge, as the app does, and hangs up once two frames
        /// have come back, recording them.
        case afterChallengeAndTwoFrames
    }

    private struct Handshake {
        let challenge: AuthChallengeFrame
        let frames: [MessageFrameScanner.Frame]
    }

    private let initialize = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n".utf8)

    private func startApp(hangUp: HangUp) async throws -> NWEndpoint.Port {
        let app = try await StandInApp.shared.value
        app.hangUp = hangUp
        return app.port
    }

    /// One listener stands in for the app for the whole run. A listener per
    /// test can be given the port of a client that just closed while the
    /// proxy is given that client's listener port, and the proxy's connect
    /// then fails with EADDRINUSE. See
    /// docs/solutions/integrations/loopback-connect-port-collision.md.
    private final class StandInApp: @unchecked Sendable {
        static let shared = Task {
            let app = try StandInApp()
            app.port = try await app.listener.startUntilReady(queue: app.queue)
            return app
        }

        private(set) var port: NWEndpoint.Port = .any
        private let listener: NWListener
        private let queue = DispatchQueue(label: "StdinRecoveryTests.StandInApp")
        private let lock = NSLock()
        private var mode = HangUp.onAccept
        private var recorded: Handshake?

        /// How the next accepted connection is hung up.
        var hangUp: HangUp {
            get { lock.withLock { mode } }
            set { lock.withLock { mode = newValue } }
        }

        /// What the last `.afterChallengeAndTwoFrames` connection received,
        /// set before it is hung up.
        var handshake: Handshake? { lock.withLock { recorded } }

        private init() throws {
            listener = try NWListener(using: WireContract.loopbackParameters())
            listener.newConnectionHandler = { [weak self] in self?.accepted($0) }
        }

        private func accepted(_ connection: NWConnection) {
            connection.start(queue: queue)
            switch hangUp {
            case .onAccept:
                connection.cancel()
            case .afterFirstBytes:
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                    connection.cancel()
                }
            case .afterChallengeAndTwoFrames:
                lock.withLock { recorded = nil }
                let challenge = AuthChallengeFrame(connectionID: UUID())
                connection.send(content: challenge.encode(), completion: .idempotent)
                receiveFrames(on: connection, into: FrameCollector()) { [weak self] frames in
                    self?.lock.withLock { self?.recorded = Handshake(challenge: challenge, frames: frames) }
                    connection.cancel()
                }
            }
        }

        /// Touched only from the connection's callbacks, which run one at a
        /// time on `queue`.
        private final class FrameCollector: @unchecked Sendable {
            var scanner = MessageFrameScanner()
            var frames: [MessageFrameScanner.Frame] = []
        }

        private func receiveFrames(
            on connection: NWConnection,
            into collector: FrameCollector,
            done: @escaping @Sendable ([MessageFrameScanner.Frame]) -> Void
        ) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
                [weak self] data, _, isComplete, error in
                collector.frames += collector.scanner.consume(data ?? Data())
                if collector.frames.count >= 2 || isComplete || error != nil {
                    done(collector.frames)
                } else {
                    self?.receiveFrames(on: connection, into: collector, done: done)
                }
            }
        }
    }

    /// Runs the proxy until the app hangs up and returns what `MCPService`
    /// would do next.
    private func recoveryAfterHangUp(
        _ hangUp: HangUp,
        clientSends bytes: Data?,
        readSigningKey: @escaping @Sendable () -> P256.Signing.PrivateKey? = { P256.Signing.PrivateKey() }
    ) async throws -> CLIBootstrap.ProxyFailureRecovery {
        let stdin = Pipe()
        if let bytes {
            try stdin.fileHandleForWriting.write(contentsOf: bytes)
        }
        let proxy = StdioProxy(
            endpoint: .hostPort(host: "127.0.0.1", port: try await startApp(hangUp: hangUp)),
            isLoopback: true,
            log: testLog,
            stdin: FileDescriptor(rawValue: stdin.fileHandleForReading.fileDescriptor),
            readSigningKey: readSigningKey
        )
        do {
            try await proxy.start()
            XCTFail("The proxy outlived its connection")
            return .rediscover
        } catch {
            return CLIBootstrap.recovery(after: error, proxy: proxy)
        }
    }

    func testAppHangingUpAfterTheClientSpokeEndsTheProcess() async throws {
        let recovery = try await recoveryAfterHangUp(.afterFirstBytes, clientSends: initialize)
        XCTAssertEqual(recovery, .terminate)
    }

    func testAppHangingUpOnASilentClientReconnects() async throws {
        let recovery = try await recoveryAfterHangUp(.onAccept, clientSends: nil)
        XCTAssertEqual(recovery, .reconnect)
    }

    /// The key is read before the socket opens, so a read slower than
    /// `HandshakeDeadline.authResponseWait` (a Keychain prompt) still has the
    /// signed answer reach the app ahead of the client's initialize, which
    /// is already waiting on stdin. It used to be read after connecting, and
    /// the initialize went first: a paired client was asked about by hand.
    func testASlowSigningKeyReadStillAnswersTheChallengeBeforeInitialize() async throws {
        let key = P256.Signing.PrivateKey()
        let slowRead: TimeInterval = 1
        XCTAssertGreaterThan(Duration.seconds(slowRead), HandshakeDeadline.authResponseWait)
        let recovery = try await recoveryAfterHangUp(.afterChallengeAndTwoFrames, clientSends: initialize) {
            Thread.sleep(forTimeInterval: slowRead)
            return key
        }
        XCTAssertEqual(recovery, .terminate)

        let recorded = try await StandInApp.shared.value.handshake
        let handshake = try XCTUnwrap(recorded)
        guard handshake.frames.count == 2, case .authResponse(let response) = handshake.frames[0] else {
            return XCTFail("the first frame was not the auth response: \(handshake.frames)")
        }
        XCTAssertEqual(
            AuthResponseFrame.verifiedFingerprint(response: response, challenge: handshake.challenge),
            ClientKeyStore.publicKeyFingerprint(for: key)
        )
        XCTAssertEqual(handshake.frames[1], .message(Data(initialize.dropLast())))
    }

    /// The order the handshake waits work in; `HandshakeDeadline` says why.
    func testTheHandshakeWaitsFitInsideTheSetupDeadline() {
        XCTAssertLessThan(HandshakeDeadline.authResponseWait, HandshakeDeadline.pairedLookup)
        XCTAssertLessThan(
            HandshakeDeadline.authResponseWait + HandshakeDeadline.pairedLookup,
            HandshakeDeadline.setup
        )
    }

    /// The gap the flag used to miss: fd 0 has been drained, and nothing has
    /// taken the bytes out of the stream yet.
    func testBytesReadButNeverForwardedStillCount() throws {
        let stdin = Pipe()
        try stdin.fileHandleForWriting.write(contentsOf: initialize)
        let readEnd = stdin.fileHandleForReading.fileDescriptor
        let latch = StdinReadLatch()
        let unreadStream = try stdinStream(
            from: FileDescriptor(rawValue: readEnd),
            bufferSize: 4096,
            latch: latch
        )

        var unread = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
        let deadline = Date().addingTimeInterval(5)
        while poll(&unread, 1, 0) != 0, Date() < deadline {
            usleep(1000)
        }
        XCTAssertEqual(poll(&unread, 1, 0), 0, "the stream never read the pipe")

        XCTAssertTrue(latch.seal())
        withExtendedLifetime(unreadStream) {}
    }

    func testASealedLatchRunsNoRead() {
        let latch = StdinReadLatch()
        XCTAssertFalse(latch.seal())

        XCTAssertNil(latch.read { 1 })
        XCTAssertFalse(latch.seal())
    }
}
