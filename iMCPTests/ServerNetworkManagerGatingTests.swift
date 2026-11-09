import CryptoKit
import MCP
import Network
import XCTest

@testable import iMCP

final class ServerNetworkManagerGatingTests: XCTestCase {
    private var clients: [LoopbackClient] = []

    override func tearDown() {
        clients.forEach { $0.close() }
        clients = []
        super.tearDown()
    }

    /// Reads as empty and persists nothing; these tests never pair a client.
    private func storage() -> PairedClientStorage {
        InMemoryKeychainItem(failSave: true).pairedClientStorage
    }

    private func connect(to manager: ServerNetworkManager) async throws -> LoopbackClient {
        let client = try await LoopbackClient.connect(to: manager)
        clients.append(client)
        return client
    }

    /// Approval belongs to a live connection. An ID nothing accepted, or one
    /// whose connection was removed, must not come back approved and let a
    /// later connection inherit the grant.
    func testApprovalLastsUntilTheConnectionIsRemoved() async throws {
        let prompt = ApprovalPromptRecorder(answer: .approved(pair: false))
        let manager = await makeServerNetworkManager(storage: storage(), prompt: prompt.prompt)

        let neverAccepted = UUID()
        await manager.removeConnection(neverAccepted)
        var isApproved = await manager.isConnectionApproved(neverAccepted)
        XCTAssertFalse(isApproved)

        let client = try await connect(to: manager)
        try await client.authenticate(with: P256.Signing.PrivateKey())
        try await client.initialize()
        let id = try XCTUnwrap(client.challenge?.connectionID)
        isApproved = await manager.isConnectionApproved(id)
        XCTAssertTrue(isApproved)

        await manager.setEnabled(false)
        isApproved = await manager.isConnectionApproved(id)
        XCTAssertFalse(isApproved)
        try await client.waitForClose()
    }

    /// Behavior decision 8: a client that goes away while its request is on
    /// the approval prompt withdraws it at once, not on a later poll.
    func testClosingTheConnectionWithdrawsItsApprovalRequestAtOnce() async throws {
        let gate = AsyncGate()
        let prompt = ApprovalPromptRecorder(gate: gate)
        let manager = await makeServerNetworkManager(storage: storage(), prompt: prompt.prompt)

        let client = try await connect(to: manager)
        try await client.authenticate(with: P256.Signing.PrivateKey())
        let initialize = Task { try await client.initialize() }
        await gate.waitUntilWaiting()

        client.close()
        try await withDeadline(LoopbackClient.deadline, throwing: NWError.posix(.ETIMEDOUT)) {
            await prompt.waitForCancellations()
        }
        initialize.cancel()
    }

    /// Switching iMCP off (or restarting the listener) withdraws every request
    /// still waiting on the prompt, so none is left unanswered.
    func testSwitchingOffWithdrawsEveryWaitingRequest() async throws {
        let gate = AsyncGate()
        let prompt = ApprovalPromptRecorder(gate: gate)
        let manager = await makeServerNetworkManager(storage: storage(), prompt: prompt.prompt)

        var initializes: [Task<Void, Error>] = []
        for _ in 0 ..< 2 {
            let client = try await connect(to: manager)
            try await client.authenticate(with: P256.Signing.PrivateKey())
            initializes.append(Task { try await client.initialize() })
        }
        await gate.waitUntilWaiting(count: 2)

        await manager.setEnabled(false)

        try await withDeadline(LoopbackClient.deadline, throwing: NWError.posix(.ETIMEDOUT)) {
            await prompt.waitForCancellations(count: 2)
        }
        for initialize in initializes {
            let result = await initialize.result
            XCTAssertThrowsError(try result.get(), "The connection closes without an answer")
        }
    }

    /// A session that keeps asking for tools without being approved is closed
    /// on its third request, so its client reconnects and starts over.
    func testUnapprovedSessionIsClosedOnItsThirdRequest() async throws {
        let manager = await makeServerNetworkManager(
            storage: storage(),
            prompt: ApprovalPromptRecorder().prompt
        )
        let client = try await connect(to: manager)
        try await client.authenticate(with: P256.Signing.PrivateKey())

        var rejections = 0
        var closed = false
        for _ in 0 ..< 10 {
            do {
                try await client.request("tools/list")
                XCTFail("tools/list must not succeed before approval")
            } catch let error as LoopbackClient.ReplyError {
                // A request that lands before the handlers are registered is
                // refused by the SDK and does not count.
                if error.message.contains("not approved") { rejections += 1 }
            } catch {
                closed = true
                break
            }
        }

        XCTAssertTrue(closed)
        XCTAssertEqual(rejections, ConnectionSession.unapprovedRequestLimit - 1)
    }

    /// A host with no listener never listens, however often it is switched on.
    func testWithoutAListenerTheManagerNeverListens() async {
        let manager = await makeServerNetworkManager(storage: storage(), prompt: ApprovalPromptRecorder().prompt)
        await manager.setEnabled(true)
        await manager.setEnabled(true)
        let state = await manager.listenerState
        XCTAssertEqual(state, .stopped)
    }

    /// iMCP switched on with no listener it could make says so, instead of
    /// showing on while no client can connect.
    @MainActor
    func testAListenerThatCannotBeMadeShowsAsFailed() async {
        let manager = ServerNetworkManager(
            listener: NetworkDiscoveryManager { throw NWError.posix(.EADDRINUSE) },
            pairedClients: PairedClientStore(storage: storage()),
            pairingCodes: PairingCodeIssuer(),
            entries: [],
            clock: .live,
            prompt: ApprovalPromptRecorder().prompt
        )
        let failed = expectation(description: "listener failed")
        let controller = ServerController(networkManager: manager, entries: [], defaults: makeTemporaryDefaults())
        let subscription = controller.$isListenerFailed.sink { if $0 { failed.fulfill() } }
        defer { subscription.cancel() }

        await fulfillment(of: [failed], timeout: 5)
        let state = await manager.listenerState
        XCTAssertEqual(state, .failed)
    }

    /// The test bundle runs inside the real app. That host must stay inert:
    /// no listener, no production pairing list, no replay of the stored
    /// iCloud session against Apple.
    @MainActor
    func testAppHostIsInertUnderTests() async {
        XCTAssertEqual(HostMode.current, .testHost)
        let environment = AppEnvironment.shared
        let controller = environment.serverController
        XCTAssertTrue(controller.serviceSwitches.isEmpty, "The test host lists no services")
        await controller.settle()
        var state = await controller.networkManager.listenerState
        XCTAssertEqual(state, .stopped)
        await controller.networkManager.setEnabled(true)
        state = await controller.networkManager.listenerState
        XCTAssertEqual(state, .stopped)
        XCTAssertFalse(controller.isListenerFailed)
        XCTAssertEqual(environment.pairedClients.clients, [])
        XCTAssertEqual(environment.iCloud.state, .signedOut)
    }

}
