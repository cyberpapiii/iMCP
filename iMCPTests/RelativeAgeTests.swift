import Foundation
import XCTest

@testable import iMCP

final class RelativeAgeTests: XCTestCase {
    func testRelativeAgeIsCoarse() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(RelativeAge.text(since: now.addingTimeInterval(-5), now: now), "just now")
        XCTAssertEqual(RelativeAge.text(since: now.addingTimeInterval(-3_599), now: now), "59m ago")
        XCTAssertEqual(RelativeAge.text(since: now.addingTimeInterval(-7_200), now: now), "2h ago")
        XCTAssertEqual(RelativeAge.text(since: now.addingTimeInterval(-200_000), now: now), "2d ago")
    }
}
