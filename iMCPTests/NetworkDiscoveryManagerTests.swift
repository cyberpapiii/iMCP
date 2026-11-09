import Network
import XCTest

@testable import iMCP

final class NetworkDiscoveryManagerTests: XCTestCase {
    /// How long a test waits for the manager before it fails, so a listener
    /// that never comes back fails its test instead of hanging the run.
    private static let waitLimit: Duration = .seconds(10)

    private struct WaitTimedOut: Error, CustomStringConvertible {
        var description: String { "The manager did not reach the awaited state within \(waitLimit)" }
    }

    private var clock: TestClock!
    private var manager: NetworkDiscoveryManager!
    private var changes: AsyncStream<Void>!
    private var onChange: (@Sendable () -> Void)!
    private var finishChanges: (@Sendable () -> Void)!

    override func setUp() async throws {
        clock = TestClock()
        manager = NetworkDiscoveryManager(clock: clock.wallClock, makeListener: Self.makeUnadvertisedListener)
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        changes = stream
        onChange = { continuation.yield() }
        finishChanges = { continuation.finish() }
    }

    override func tearDown() async throws {
        await manager.stop()
        manager = nil
    }

    /// Test listeners do not advertise. The test host's Info.plist declares
    /// only "_mcp._tcp" in NSBonjourServices, and macOS fails a listener
    /// that advertises any other type with -65555 NoAuth a few milliseconds
    /// after `.ready`. Advertising "_mcp._tcp" would compete with the
    /// running app.
    @Sendable private static func makeUnadvertisedListener() throws -> NWListener {
        try NWListener(using: WireContract.loopbackParameters())
    }

    private func start() async {
        await manager.start(onChange: onChange, onConnection: { _ in })
    }

    /// Runs `wait` over the manager's changes, and throws after `waitLimit`.
    /// A timeout finishes the change stream, so the abandoned wait ends too
    /// instead of iterating beside a later one.
    private func waitOnChanges<T: Sendable>(
        _ wait: @escaping @Sendable (AsyncStream<Void>, NetworkDiscoveryManager) async -> T
    ) async throws -> T {
        let changes = changes!
        let manager = manager!
        let finishChanges = finishChanges!
        return try await withDeadline(Self.waitLimit, throwing: WaitTimedOut(), onTimeout: finishChanges) {
            await wait(changes, manager)
        }
    }

    /// Returns once the manager reports `matching`.
    private func waitForState(
        _ matching: @escaping @Sendable (NetworkDiscoveryManager.State) -> Bool
    ) async throws -> NetworkDiscoveryManager.State {
        try await waitOnChanges { changes, manager in
            var iterator = changes.makeAsyncIterator()
            var state = await manager.state
            while !matching(state), await iterator.next() != nil {
                state = await manager.state
            }
            return state
        }
    }

    private func waitForReplacement(of original: NWListener) async throws -> NWListener? {
        try await waitOnChanges { changes, manager in
            var iterator = changes.makeAsyncIterator()
            while true {
                if case .listening = await manager.state, let current = await manager.listener, current !== original {
                    return current
                }
                guard await iterator.next() != nil else { return nil }
            }
        }
    }

    private func waitUntilListening() async throws -> NWListener? {
        _ = try await waitForState { if case .listening = $0 { true } else { false } }
        return await manager.listener
    }

    func testTheListenerAdvertisesTheIMCPService() throws {
        let service = try XCTUnwrap(NetworkDiscoveryManager.makeListener().service)
        XCTAssertEqual(service.name, WireContract.bonjourInstanceName)
        XCTAssertEqual(service.type, WireContract.serviceType)
        XCTAssertEqual(service.domain, WireContract.serviceDomain)
    }

    func testStartListensOnAPortAndStopForgetsTheListener() async throws {
        await start()
        let state = try await waitForState { if case .listening = $0 { true } else { false } }
        guard case .listening(let port) = state else { return XCTFail("\(state)") }
        let listener = await manager.listener
        XCTAssertEqual(listener?.port?.rawValue, port)

        await manager.stop()
        let stopped = await manager.state
        let after = await manager.listener
        XCTAssertEqual(stopped, .stopped)
        XCTAssertNil(after)
    }

    /// A stopped listener's own late `.cancelled` must not reach the manager,
    /// or a quick off and on would tear down the fresh listener.
    func testStartAfterStopBuildsAFreshListenerAndSilencesTheOldOne() async throws {
        await start()
        let originalListener = try await waitUntilListening()
        let original = try XCTUnwrap(originalListener)

        await manager.stop()
        XCTAssertNil(original.stateUpdateHandler)
        XCTAssertNil(original.newConnectionHandler)

        await start()
        let replacementListener = try await waitUntilListening()
        let replacement = try XCTUnwrap(replacementListener)
        XCTAssertFalse(replacement === original)
        XCTAssertNotNil(replacement.newConnectionHandler)
        XCTAssertNotNil(replacement.stateUpdateHandler)
    }

    /// Something outside cancelling the listener does not leave iMCP deaf:
    /// a new one takes its place, with the handlers carried over.
    func testAnUnexpectedCancelIsReplacedWithAFreshListener() async throws {
        await start()
        let originalListener = try await waitUntilListening()
        let original = try XCTUnwrap(originalListener)

        original.cancel()

        let replacementListener = try await waitForReplacement(of: original)
        let replacement = try XCTUnwrap(replacementListener)
        XCTAssertNotNil(replacement.newConnectionHandler)
        XCTAssertNotNil(replacement.stateUpdateHandler)
    }

    /// CI's macOS reported a refused advertisement (-65555 NoAuth) as the
    /// listener was cancelled from outside, and then the cancel. The cancel
    /// replaces the listener at once, and the failure's delayed recovery
    /// does not replace it a second time.
    func testAFailureReportedWithAnUnexpectedCancelIsReplacedOnceWithoutTheDelay() async throws {
        await start()
        let originalListener = try await waitUntilListening()
        let original = try XCTUnwrap(originalListener)

        original.stateUpdateHandler?(.failed(.dns(-65555)))
        original.cancel()

        let replacementListener = try await waitForReplacement(of: original)
        let replacement = try XCTUnwrap(replacementListener)
        clock.advance(by: NetworkDiscoveryManager.failureRecoveryDelay)
        await manager.settle()
        let current = await manager.listener
        XCTAssertTrue(current === replacement, "The failure's recovery was called off")
    }

    func testAFailedListenerIsReplacedAfterTheRecoveryDelay() async throws {
        await start()
        let originalListener = try await waitUntilListening()
        let original = try XCTUnwrap(originalListener)

        original.stateUpdateHandler?(.failed(.posix(.ENETDOWN)))
        _ = try await waitForState { $0 == .starting }
        let waiting = await manager.listener
        XCTAssertTrue(waiting === original, "Nothing is replaced before the delay")

        clock.advance(by: NetworkDiscoveryManager.failureRecoveryDelay)
        let replacement = try await waitForReplacement(of: original)
        XCTAssertNotNil(replacement)
    }

    /// Switching iMCP off while a failed listener waits to be replaced must
    /// not bring a listener back.
    func testStoppingDuringTheRecoveryDelayCallsTheRecoveryOff() async throws {
        await start()
        let originalListener = try await waitUntilListening()
        let original = try XCTUnwrap(originalListener)

        original.stateUpdateHandler?(.failed(.posix(.ENETDOWN)))
        _ = try await waitForState { $0 == .starting }
        await manager.stop()
        clock.advance(by: NetworkDiscoveryManager.failureRecoveryDelay)
        await manager.settle()

        let state = await manager.state
        let listener = await manager.listener
        XCTAssertEqual(state, .stopped)
        XCTAssertNil(listener)
    }

    /// A listener that cannot be made says so instead of passing for on,
    /// and the next start tries again.
    func testAListenerThatCannotBeMadeReportsFailure() async throws {
        let attempts = Counter()
        manager = NetworkDiscoveryManager(clock: clock.wallClock) {
            attempts.increment()
            throw NWError.posix(.EADDRINUSE)
        }
        await start()
        let state = try await waitForState { $0 == .failed }
        XCTAssertEqual(state, .failed)

        await start()
        XCTAssertEqual(attempts.value, 2)
    }
}
