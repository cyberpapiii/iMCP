import XCTest

@testable import iMCP

final class BrowserHistoryServiceTests: XCTestCase {
    func testChromiumTimestampRoundTrips() {
        // Chromium stores microseconds since 1601-01-01; the conversion must
        // round-trip to the original instant.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = Browser.chrome.timestamp(from: date)
        let restored = Browser.chrome.date(fromTimestamp: stored)
        XCTAssertEqual(restored.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testChromiumEpochAnchor() {
        // The Unix epoch is 11644473600 seconds after the WebKit epoch, in
        // microseconds.
        let stored = Browser.arc.timestamp(from: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(stored, 11_644_473_600 * 1_000_000, accuracy: 1)
    }

    func testSafariTimestampUsesCoreDataEpoch() {
        // Safari stores seconds since 2001-01-01, so the Core Data reference
        // date maps to zero.
        let referenceDate = Date(timeIntervalSince1970: 978_307_200)
        XCTAssertEqual(Browser.safari.timestamp(from: referenceDate), 0, accuracy: 0.001)
    }
}
