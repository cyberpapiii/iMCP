import Foundation
import XCTest

/// `Latch` is what keeps a blocked Keychain read, or an app that never sends
/// an auth challenge, from parking a continuation that nobody ever resumes.
/// The invariant under test is that every waiter comes back exactly once,
/// whether the latch opens or its deadline retires it first.
final class LatchTests: XCTestCase {
    func testOpeningReleasesEveryWaiter() async {
        let latch = Latch()
        async let first = latch.wait(within: .seconds(30))
        async let second = latch.wait(within: .seconds(30))
        await latch.open()

        let results = await [first, second]
        XCTAssertEqual(results, [true, true])
    }

    func testAWaitAfterOpeningReturnsAtOnceAndOpeningTwiceIsHarmless() async {
        let latch = Latch()
        await latch.open()
        await latch.open()
        let opened = await latch.wait(within: .seconds(30))
        XCTAssertTrue(opened)
    }

    /// A deadline retiring one waiter must not disturb the others, and the
    /// retired waiter is not handed back a second time when the latch opens.
    func testADeadlineRetiresOnlyItsWaiter() async {
        let latch = Latch()
        async let kept = latch.wait(within: .seconds(30))
        let retired = await latch.wait(within: .milliseconds(10))
        XCTAssertFalse(retired)

        await latch.open()
        let keptResult = await kept
        XCTAssertTrue(keptResult)
    }

    func testCancellingAWaitReturnsUnopened() async {
        let latch = Latch()
        let waiting = Task { await latch.wait(within: .seconds(30)) }
        waiting.cancel()
        let result = await waiting.value
        XCTAssertFalse(result)
    }
}
