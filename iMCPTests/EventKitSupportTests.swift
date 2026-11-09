import EventKit
import XCTest

@testable import iMCP

final class EventKitSupportTests: XCTestCase {
    /// A typo used to filter for `none` or `busy` instead of failing.
    func testAnUnknownStatusOrAvailabilityFilterIsRejected() {
        XCTAssertThrowsError(try ToolArgument.choice("status", among: EKEventStatus.names)(["status": "cancelled"])) {
            XCTAssertEqual(
                sanitizedToolErrorMessage(for: $0),
                "Invalid status. Expected one of: none, tentative, confirmed, canceled."
            )
        }
        XCTAssertThrowsError(
            try ToolArgument.choice("availability", among: EKEventAvailability.names)(["availability": "bussy"])
        )
        XCTAssertEqual(try ToolArgument.choice("status", among: EKEventStatus.names)(["status": "Canceled"]), .canceled)
        XCTAssertNil(try ToolArgument.choice("availability", among: EKEventAvailability.names)([:]))
    }

    /// The schema enums are read from the same tables, in this order; a
    /// reordering would change the cached tools/list payload.
    func testTablesKeepTheirSchemaOrder() {
        XCTAssertEqual(EKEventStatus.names.names, ["none", "tentative", "confirmed", "canceled"])
        XCTAssertEqual(EKEventAvailability.names.names, ["busy", "free", "tentative", "unavailable"])
        XCTAssertEqual(EKReminderPriority.names.names, ["none", "low", "medium", "high"])
    }

    func testEachEntityNamesItsOwnContainersAndListTool() {
        XCTAssertThrowsError(try EventKitEntity.events.requireSingleContainer([String](), named: "Wrok")) {
            XCTAssertEqual(
                sanitizedToolErrorMessage(for: $0),
                "Calendar not found: Wrok. Call calendars_list for valid names."
            )
        }
        XCTAssertEqual(EventKitEntity.reminders.listTool, "reminders_lists")
    }

    func testCalendarOmittedDatesUseNowThroughNextWeek() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let window = try calendarEventsFetchWindow(from: [:], now: now, calendar: calendar)
        XCTAssertEqual(window.start, now)
        XCTAssertEqual(window.end, calendar.date(byAdding: .weekOfYear, value: 1, to: now))
    }

    func testCalendarAcceptsStartAndStartDateAliases() throws {
        let formatter = ISO8601DateFormatter()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let viaStart = try calendarEventsFetchWindow(from: [
            "start": .string(formatter.string(from: start))
        ])
        let viaStartDate = try calendarEventsFetchWindow(from: [
            "startDate": .string(formatter.string(from: start))
        ])
        XCTAssertEqual(viaStart.start.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(
            viaStartDate.start.timeIntervalSince1970,
            start.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testCalendarDateOnlyOmittedStartUsesEndMidnight() throws {
        let calendar = Calendar.current
        let window = try calendarEventsFetchWindow(
            from: ["end": .string("2026-07-04")],
            now: Date(timeIntervalSince1970: 1_700_000_000),
            calendar: calendar
        )
        let expectedStart = calendar.startOfDay(
            for: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 4)))
        )
        let expectedEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: expectedStart))
        XCTAssertEqual(window.start, expectedStart)
        XCTAssertEqual(window.end, expectedEnd)
    }

    func testRemindersNilFetchThrowsAndEmptySucceeds() throws {
        XCTAssertThrowsError(try remindersFetchResult(nil).get()) { error in
            XCTAssertEqual(sanitizedToolErrorMessage(for: error), "Reminders fetch failed")
        }
        XCTAssertEqual(try remindersFetchResult([]).get(), [])
    }

    /// EventKit hands back a date-only end, which lands at midnight and reads as
    /// the event ending the instant its last day begins. The bounds have to
    /// stretch that to 23:59:59 or a query for July 4 misses the event.
    func testAllDayEventBoundsKeepDateOnlyEndOnRequestedDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let startDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 14))
        )
        let endDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 4)))

        let bounds = allDayEventBounds(
            startDate: startDate,
            endDate: endDate,
            endIsDateOnly: true,
            calendar: calendar
        )

        XCTAssertEqual(calendar.component(.day, from: bounds.start), 2)
        XCTAssertEqual(calendar.component(.hour, from: bounds.start), 0)
        XCTAssertEqual(calendar.component(.day, from: bounds.end), 4)
        XCTAssertEqual(calendar.component(.hour, from: bounds.end), 23)
        XCTAssertEqual(calendar.component(.minute, from: bounds.end), 59)
        XCTAssertEqual(calendar.component(.second, from: bounds.end), 59)
    }

    func testUnknownCalendarNameReachesTheCaller() {
        XCTAssertThrowsError(
            try EventKitEntity.reminders.requireSingleContainer([String](), named: "Wrok")
        ) { error in
            XCTAssertEqual(
                sanitizedToolErrorMessage(for: error),
                "Reminder list not found: Wrok. Call reminders_lists for valid names."
            )
        }
    }

    func testAmbiguousCalendarNameReachesTheCaller() {
        XCTAssertThrowsError(
            try EventKitEntity.events.requireSingleContainer(["a", "b"], named: "Home")
        ) { error in
            XCTAssertTrue(sanitizedToolErrorMessage(for: error).hasPrefix("Calendar name is ambiguous: Home."))
        }
    }

    func testASingleMatchIsReturned() throws {
        XCTAssertEqual(
            try EventKitEntity.events.requireSingleContainer(["only"], named: "Only"),
            "only"
        )
    }

    func testAlarmOffsetIsBoundedInsteadOfOverflowing() throws {
        XCTAssertEqual(try alarmRelativeOffset(minutes: .int(15)), -900)
        XCTAssertEqual(try alarmRelativeOffset(minutes: .int(-10)), 600)
        XCTAssertEqual(try alarmRelativeOffset(minutes: .double(5.0)), -300)
        for value: Value in [.int(Int.max), .int(Int.min), .string("15")] {
            XCTAssertThrowsError(try alarmRelativeOffset(minutes: value)) { error in
                XCTAssertTrue(error is ToolInputError)
            }
        }
    }

    func testRequestedNamesNarrowCaseInsensitively() throws {
        func narrow(_ names: Value?) throws -> [String] {
            let requested = try ToolArgument<[String]?>.strings("calendars")(names.map { ["calendars": $0] } ?? [:])
            return try EventKitEntity.events.itemsMatchingRequestedNames(
                ["Work", "Home"],
                names: requested,
                title: { $0 }
            )
        }
        XCTAssertEqual(try narrow(.array([.string("work")])), ["Work"])
        XCTAssertEqual(try narrow(nil), ["Work", "Home"])
        XCTAssertEqual(try narrow(.null), ["Work", "Home"])
        XCTAssertEqual(try narrow(.array([])), ["Work", "Home"])
        XCTAssertThrowsError(try narrow(.array([.int(1)])))
        XCTAssertThrowsError(try narrow(.string("Work")))
    }

    func testUnknownRequestedNameReachesTheCaller() {
        XCTAssertThrowsError(
            try EventKitEntity.events.itemsMatchingRequestedNames(
                ["Work", "Home"],
                names: ["Wrok"],
                title: { $0 }
            )
        ) { error in
            XCTAssertEqual(
                sanitizedToolErrorMessage(for: error),
                "Calendar not found: Wrok. Call calendars_list for valid names."
            )
        }
    }
}
