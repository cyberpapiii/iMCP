import Foundation
import XCTest

extension XCTestCase {
    /// Returns once `condition` holds, or fails the test after
    /// `CountLatch.deadline`. Only for state nothing announces, such as
    /// AppKit layout; work a test can count should reach a `CountLatch`
    /// instead.
    @MainActor
    func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: CountLatch.deadline)
        while !condition() {
            guard clock.now < deadline else {
                return XCTFail("condition not met within \(CountLatch.deadline)", file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
