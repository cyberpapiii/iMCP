import ServiceLifecycle
import ServiceLifecycleTestKit
import XCTest

final class ServiceGroupConfigurationTests: XCTestCase {
    /// The reconnect loop in `MCPService.run()` spins on
    /// `while !Task.isShuttingDownGracefully`. If that task-local ever stopped
    /// flipping, the CLI would keep reconnecting through a graceful shutdown.
    func testTaskIsShuttingDownGracefullyObservedAfterTrigger() async throws {
        await testGracefulShutdown { trigger in
            XCTAssertFalse(Task.isShuttingDownGracefully)
            trigger.triggerGracefulShutdown()
            XCTAssertTrue(Task.isShuttingDownGracefully)
        }
    }
}
