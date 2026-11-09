import Foundation
import XCTest

@testable import iMCP

final class DeadlinedValueTests: XCTestCase {
    func testReturnsTheValueOnceItArrives() async {
        let gate = DispatchSemaphore(value: 0)
        let reader = DeadlinedValue<Int> {
            gate.wait()
            return 7
        }

        let timedOut = await reader.value(within: .milliseconds(50))
        XCTAssertNil(timedOut)

        gate.signal()
        let arrived = await reader.value(within: .seconds(5))
        XCTAssertEqual(arrived, 7)
    }

    /// The read is expensive and may prompt the user. Two callers must not
    /// produce two prompts.
    func testReadRunsOnlyOnce() async {
        let counter = Counter()
        let reader = DeadlinedValue<Int> {
            counter.increment()
        }

        async let first = reader.value(within: .seconds(5))
        async let second = reader.value(within: .seconds(5))
        let results = await [first, second]

        XCTAssertEqual(results, [1, 1])
        XCTAssertEqual(counter.value, 1)
    }

    /// The Swift concurrency pool has one thread per core and does not grow.
    /// Reads that blocked on it used to fill it, after which no task ran, the
    /// deadline that should have released the caller included. Synchronous,
    /// so the wait itself does not need the pool.
    func testBlockedReadsLeaveTheConcurrencyPoolFree() {
        let gate = DispatchSemaphore(value: 0)
        let readers = (0 ... ProcessInfo.processInfo.activeProcessorCount).map { _ in
            DeadlinedValue<Int> {
                gate.wait()
                return 0
            }
        }
        defer { readers.forEach { _ in gate.signal() } }

        let deadlinePassed = expectation(description: "a deadline still passes")
        Task {
            for reader in readers { await reader.start() }
            let probe = await readers[0].value(within: .milliseconds(50))
            XCTAssertNil(probe)
            deadlinePassed.fulfill()
        }
        wait(for: [deadlinePassed], timeout: 10)
    }
}
