import Contacts
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import iMCP

/// events_create and reminders_create parse through the shared lenient parser,
/// which read the `-05` ending `2026-10-05` as a timezone offset and rejected
/// every date-only value.
final class LenientDateOnlyTests: XCTestCase {
    func testDateOnlyParsesToLocalMidnight() throws {
        for string in ["2026-10-05", "2026-10-15", "2026-12-31"] {
            let parsed = try XCTUnwrap(
                ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: string),
                string
            )
            XCTAssertTrue(parsed.isDateOnly)
            XCTAssertEqual(parsed.date, Calendar.current.startOfDay(for: parsed.date), string)
        }
    }

    func testAnOffsetAfterATimeIsStillNotReadAsLocalTime() {
        // No formatter accepts a minutes-only time with an offset; falling back
        // to local time would drop the offset and shift the instant.
        XCTAssertNil(ISO8601DateFormatter.lenientDate(fromISO8601String: "2026-10-05T09:00-04:00"))
    }
}

final class LocalISO8601Tests: XCTestCase {
    func testTimestampsCarryTheLocalOffsetAndRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let string = date.localISO8601

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let local = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = TimeZone.current.secondsFromGMT(for: date)
        let suffix =
            offset == 0
            ? "Z"
            : String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
        let expected = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            local.year!,
            local.month!,
            local.day!,
            local.hour!,
            local.minute!,
            local.second!
        )
        XCTAssertEqual(string, expected + suffix)

        let parsed = try XCTUnwrap(ISO8601DateFormatter().date(from: string))
        XCTAssertEqual(parsed, date)
    }
}
