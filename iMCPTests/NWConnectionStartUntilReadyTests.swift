import Network
import XCTest

@testable import iMCP

final class NWConnectionStartUntilReadyTests: XCTestCase {
    /// Regression test for a CI job that hung in
    /// `testDroppedConnectionLeavesNoPairingCodeTrust`: a connect whose ports
    /// collide with an earlier connection's never becomes ready, so it must
    /// fail at once, not wait out its timeout (or forever, with none).
    func testAConnectThatCollidesWithAnEarlierConnectionFailsAtOnce() async throws {
        let queue = DispatchQueue(label: "NWConnectionStartUntilReadyTests")
        let earlier = try await LoopbackSocketPair.open(queue: queue, deadline: .seconds(5))
        earlier.appEnd.start(queue: queue)
        defer { earlier.appEnd.cancel() }
        guard case .hostPort(_, let clientPort)? = earlier.client.currentPath?.localEndpoint else {
            return XCTFail("the earlier connection has no local port")
        }
        let listenerPort = try await LoopbackSocketPair.listenerPort
        earlier.client.cancel()

        let parameters = WireContract.loopbackParameters()
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: listenerPort)
        parameters.allowLocalEndpointReuse = true
        let colliding = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: clientPort, using: parameters)
        defer { colliding.cancel() }

        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await colliding.startUntilReady(queue: queue, timeout: .seconds(10))
            XCTFail("the colliding connection became ready")
        } catch let error as NWError {
            XCTAssertEqual(error, .posix(.EADDRINUSE))
        }
        XCTAssertLessThan(clock.now - started, .seconds(5))
    }
}
