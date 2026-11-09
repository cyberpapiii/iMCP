import Foundation
import XCTest

@testable import iMCP

final class LocationSettingsSectionsTests: XCTestCase {
    func testFindMyPeopleThatIsNotSetUpPointsAtTheGuide() {
        XCTAssertEqual(
            findMyPeopleStatusText(
                state: .notConfigured,
                peopleEnabled: false,
                health: FindMyPeopleHealth(lastSuccess: nil, rowCount: nil, lastErrorCategory: nil)
            ),
            "Not set up. Open the Setup Guide to start."
        )
    }
}
