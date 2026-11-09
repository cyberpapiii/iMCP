import Contacts
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import iMCP

final class DeadlineTests: XCTestCase {
    private struct TimedOut: Error {}

    func testReturnsTheOperationResultBeforeTheDeadline() async throws {
        let value = try await withDeadline(.seconds(5), throwing: TimedOut()) { 7 }
        XCTAssertEqual(value, 7)
    }

    func testThrowsTheTimeoutErrorWhenTheOperationIsSlow() async {
        let started = Date()
        do {
            _ = try await withDeadline(.milliseconds(50), throwing: TimedOut()) {
                try await Task.sleep(for: .seconds(30))
                return 7
            }
            XCTFail("a slow operation must hit the deadline")
        } catch {
            XCTAssertTrue(error is TimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// Each report used to claim the continuation from its own unstructured
    /// task, so whichever task ran first won, not whichever report came first.
    func testTheCallbackFormTakesOnlyTheFirstReport() async throws {
        let value: Int = try await withDeadline(.seconds(5), throwing: TimedOut()) { report in
            report(.success(1))
            report(.success(2))
        }
        XCTAssertEqual(value, 1)
    }

    /// A callback that answers after the deadline must not resume the
    /// continuation a second time.
    func testAReportAfterTheDeadlineIsIgnored() async {
        let late = LateReport()
        do {
            let _: Int = try await withDeadline(.milliseconds(50), throwing: TimedOut()) { report in
                late.store(report)
            }
            XCTFail("a callback that never reports in time must hit the deadline")
        } catch {
            XCTAssertTrue(error is TimedOut)
        }
        late.fire(.success(1))
    }

    func testTimeoutRunsTheCleanupBeforeThrowing() async {
        let cleanedUp = Counter()
        do {
            let _: Int = try await withDeadline(
                .milliseconds(50),
                throwing: TimedOut(),
                onTimeout: { cleanedUp.increment() }
            ) { _ in }
            XCTFail("a callback that never reports must hit the deadline")
        } catch {
            XCTAssertTrue(error is TimedOut)
        }
        XCTAssertEqual(cleanedUp.value, 1)
    }

    func testAnOperationThatFinishesSkipsTheCleanup() async throws {
        let cleanedUp = Counter()
        _ = try await withDeadline(.seconds(5), throwing: TimedOut(), onTimeout: { cleanedUp.increment() }) {
            7
        }
        XCTAssertEqual(cleanedUp.value, 0)
    }

    func testRethrowsTheOperationError() async {
        do {
            let _: Int = try await withDeadline(.seconds(5), throwing: TimedOut()) {
                throw ToolInputError("x")
            }
            XCTFail("the operation's error must surface")
        } catch {
            XCTAssertTrue(error is ToolInputError)
        }
    }
}

private final class LateReport: @unchecked Sendable {
    private let lock = NSLock()
    private var report: (@Sendable (Result<Int, Error>) -> Void)?

    func store(_ report: @escaping @Sendable (Result<Int, Error>) -> Void) {
        lock.withLock { self.report = report }
    }

    func fire(_ result: Result<Int, Error>) {
        lock.withLock { report }?(result)
    }
}
