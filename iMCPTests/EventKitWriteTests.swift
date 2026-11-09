import EventKit
import XCTest

@testable import iMCP

/// The update tools merge the caller's fields into an existing item. These
/// run on unsaved EventKit objects only: nothing here saves, removes, or
/// reads the store, so the owner's reminders and calendar are never touched.
final class WriteVerbMergeTests: XCTestCase {
    private let store = EKEventStore()

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ string: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: string))
    }

    private func assertInputError(
        _ expression: @autoclosure () throws -> Any?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertTrue(error is ToolInputError, "\(error)", file: file, line: line)
        }
    }

    // MARK: Reminders

    func testReminderUpdateLeavesUnsuppliedFieldsAlone() throws {
        let reminder = EKReminder(eventStore: store)
        reminder.title = "Buy milk"
        reminder.notes = "2%"
        reminder.priority = Int(EKReminderPriority.high.rawValue)

        try applyReminder(["notes": .string("oat")], to: reminder)

        XCTAssertEqual(reminder.title, "Buy milk")
        XCTAssertEqual(reminder.priority, Int(EKReminderPriority.high.rawValue))
        XCTAssertEqual(reminder.notes, "oat")
    }

    func testReminderCompletedTicksOffAndReopens() throws {
        let reminder = EKReminder(eventStore: store)

        try applyReminder(["completed": .bool(true)], to: reminder)
        XCTAssertTrue(reminder.isCompleted)

        try applyReminder(["completed": .bool(false)], to: reminder)
        XCTAssertFalse(reminder.isCompleted)
    }

    func testReminderCompletedRejectsANonBoolean() {
        let reminder = EKReminder(eventStore: store)
        assertInputError(try applyReminder(["completed": .string("yes")], to: reminder))
        XCTAssertFalse(reminder.isCompleted)
    }

    func testReminderEmptyAlarmsClearsAndOmittedAlarmsKeep() throws {
        let reminder = EKReminder(eventStore: store)
        reminder.alarms = [EKAlarm(relativeOffset: -600)]

        try applyReminder(["title": .string("x")], to: reminder)
        XCTAssertEqual(reminder.alarms?.count, 1)

        try applyReminder(["alarms": .array([])], to: reminder)
        XCTAssertTrue(reminder.alarms?.isEmpty ?? true)
    }

    func testReminderDueIsSetFromADateOnlyString() throws {
        let reminder = EKReminder(eventStore: store)

        try applyReminder(["due": .string("2026-12-31")], to: reminder)

        XCTAssertEqual(reminder.dueDateComponents?.year, 2026)
        XCTAssertEqual(reminder.dueDateComponents?.month, 12)
        XCTAssertEqual(reminder.dueDateComponents?.day, 31)
    }

    /// All three fail before the store is read. This is the guard that keeps
    /// `reminders_delete` and `reminders_update` from acting without a target.
    func testReminderLookupRequiresAnIdentifier() {
        assertInputError(try requireReminder(reminderIdentifier, [:], in: store))
        assertInputError(try requireReminder(reminderIdentifier, ["identifier": .string("")], in: store))
        assertInputError(try requireReminder(reminderIdentifier, ["identifier": .int(1)], in: store))
    }

    // MARK: Event dates

    func testEventRangeIsNilWhenUpdateNamesNoBound() throws {
        let current = (start: try date("2026-07-02T10:00:00Z"), end: try date("2026-07-02T11:30:00Z"))
        XCTAssertNil(try range([:], current: current))
    }

    func testEventRangeRequiresBothBoundsOnCreate() {
        assertInputError(
            try range(["start": .string("2026-07-02T10:00:00Z")])
        )
        assertInputError(try range([:]))
    }

    func testALoneStartMovesTheEventAndKeepsItsLength() throws {
        let current = (start: try date("2026-07-02T10:00:00Z"), end: try date("2026-07-02T11:30:00Z"))

        let range = try XCTUnwrap(
            try range(["start": .string("2026-07-02T14:00:00Z")], current: current)
        )

        XCTAssertEqual(range.start, try date("2026-07-02T14:00:00Z"))
        XCTAssertEqual(range.end, try date("2026-07-02T15:30:00Z"))
    }

    func testALoneEndChangesOnlyTheLength() throws {
        let current = (start: try date("2026-07-02T10:00:00Z"), end: try date("2026-07-02T11:30:00Z"))

        let range = try XCTUnwrap(
            try range(["end": .string("2026-07-02T12:00:00Z")], current: current)
        )

        XCTAssertEqual(range.start, try date("2026-07-02T10:00:00Z"))
        XCTAssertEqual(range.end, try date("2026-07-02T12:00:00Z"))
    }

    func testEventRangeRejectsAnEndBeforeTheStart() throws {
        let current = (start: try date("2026-07-02T10:00:00Z"), end: try date("2026-07-02T11:30:00Z"))
        assertInputError(
            try range(["end": .string("2026-07-02T09:00:00Z")], current: current)
        )
    }

    func testEventRangeRejectsAnUnparseableDate() {
        XCTAssertThrowsError(
            try range(["start": .string("tomorrow")])
        ) { error in
            XCTAssertEqual(sanitizedToolErrorMessage(for: error), "start must be an ISO 8601 date or date-time")
        }
    }

    func testAllDayRangeSpansWholeDays() throws {
        let range = try XCTUnwrap(
            try range([
                "isAllDay": .bool(true),
                "start": .string("2026-07-02T14:00:00Z"),
                "end": .string("2026-07-04T09:00:00Z"),
            ])
        )

        XCTAssertEqual(range.start, try date("2026-07-02T00:00:00Z"))
        XCTAssertEqual(range.end, try date("2026-07-04T23:59:59Z"))
    }

    // MARK: Events

    private func standup() throws -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = "Standup"
        event.location = "Room 4"
        event.startDate = try date("2026-07-02T10:00:00Z")
        event.endDate = try date("2026-07-02T10:15:00Z")
        event.alarms = [EKAlarm(relativeOffset: -600)]
        return event
    }

    func testEventUpdateLeavesUnsuppliedFieldsAlone() throws {
        let event = try standup()

        try applyEvent(["location": .string("Room 9")], to: event)

        XCTAssertEqual(event.title, "Standup")
        XCTAssertEqual(event.startDate, try date("2026-07-02T10:00:00Z"))
        XCTAssertEqual(event.endDate, try date("2026-07-02T10:15:00Z"))
        XCTAssertEqual(event.alarms?.count, 1)
        XCTAssertEqual(event.location, "Room 9")
    }

    func testEventAlarmsAreReplacedWhenSupplied() throws {
        let event = try standup()

        try applyEvent(["alarms": .array([])], to: event)

        XCTAssertTrue(event.alarms?.isEmpty ?? true)
    }

    /// `events_create` hands a brand-new event to the shared setter, which
    /// must still insist on both bounds for it.
    func testANewEventRequiresBothBounds() {
        let event = EKEvent(eventStore: store)
        assertInputError(try applyEvent(["title": .string("Standup")], to: event))
    }

    func testANullSpanIsReadAsAbsent() throws {
        XCTAssertEqual(try calendarEventSpan("")(["span": .null]), .thisEvent)
    }

    // MARK: Strict arguments

    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func applyReminder(_ arguments: [String: Value], to reminder: EKReminder) throws {
        try ReminderFields.update(arguments).apply(to: reminder, in: store)
    }

    private func applyEvent(_ arguments: [String: Value], to event: EKEvent) throws {
        try EventFields.update(arguments).apply(to: event, in: store)
    }

    private func range(
        _ arguments: [String: Value],
        current: (start: Date, end: Date)? = nil,
        allDay: Bool = false,
        in calendar: Calendar? = nil
    ) throws -> (start: Date, end: Date)? {
        try EventFields.update(arguments).dateRange(
            current: current.map { ($0.start, $0.end, allDay) },
            calendar: calendar ?? utc
        )
    }

    private func milk() -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.title = "Buy milk"
        reminder.notes = "2%"
        reminder.priority = Int(EKReminderPriority.high.rawValue)
        reminder.alarms = [EKAlarm(relativeOffset: -600)]
        return reminder
    }

    func testReminderUpdateChangesNothingWhenALaterArgumentIsInvalid() {
        let reminder = milk()
        assertInputError(
            try applyReminder(
                ["title": .string("New"), "notes": .string("oat"), "completed": .string("yes")],
                to: reminder
            )
        )
        XCTAssertEqual(reminder.title, "Buy milk")
        XCTAssertEqual(reminder.notes, "2%")
    }

    func testEventUpdateChangesNothingWhenALaterArgumentIsInvalid() throws {
        let event = try standup()
        assertInputError(
            try applyEvent(
                [
                    "title": .string("New"),
                    "location": .string("Room 9"),
                    "alarms": .array([.object(["type": .string("relative"), "minutes": .string("soon")])]),
                ],
                to: event
            )
        )
        XCTAssertEqual(event.title, "Standup")
        XCTAssertEqual(event.location, "Room 4")
        XCTAssertEqual(event.alarms?.map(\.relativeOffset), [-600])
    }

    func testEventAlarmsRejectAnEntryThatYieldsNoAlarm() throws {
        let unusable: [Value] = [
            .int(15),
            .object(["type": .string("weekly"), "minutes": .int(5)]),
            .object(["type": .string("relative")]),
            .object(["type": .string("absolute"), "datetime": .string("soon")]),
            .object(["type": .string("absolute")]),
            .object(["type": .string("proximity"), "locationTitle": .string("Home"), "longitude": .int(1)]),
            .object(["type": .string("proximity"), "latitude": .int(1), "longitude": .int(1)]),
            .object(["type": .string("relative"), "minutes": .int(5), "sound": .string("Kazoo")]),
        ]
        for entry in unusable {
            let event = try standup()
            assertInputError(try applyEvent(["alarms": .array([entry])], to: event))
            XCTAssertEqual(event.alarms?.map(\.relativeOffset), [-600], "\(entry)")
        }
        let event = try standup()
        assertInputError(try applyEvent(["alarms": .int(15)], to: event))
        XCTAssertEqual(event.alarms?.map(\.relativeOffset), [-600])
    }

    func testAnAlarmErrorNamesTheEntry() throws {
        let event = try standup()
        let alarms: Value = .array([.object(["minutes": .int(5)]), .int(15)])
        XCTAssertThrowsError(try applyEvent(["alarms": alarms], to: event)) { error in
            XCTAssertEqual(sanitizedToolErrorMessage(for: error), "alarms[1]: must be an object")
        }
    }

    func testEventAlarmsOfEveryKindAreSet() throws {
        let event = try standup()
        try applyEvent(
            [
                "alarms": .array([
                    .object(["minutes": .int(15), "sound": .string("Glass")]),
                    .object(["type": .string("absolute"), "datetime": .string("2026-07-02T09:00:00Z")]),
                    .object([
                        "type": .string("proximity"), "proximity": .string("leave"),
                        "locationTitle": .string("Home"), "latitude": .double(40.5), "longitude": .int(-74),
                        "radius": .int(150),
                    ]),
                ])
            ],
            to: event
        )
        // EventKit hands the alarms back in its own order.
        let alarms = try XCTUnwrap(event.alarms)
        XCTAssertEqual(alarms.count, 3)
        let relative = try XCTUnwrap(alarms.first { $0.relativeOffset != 0 })
        XCTAssertEqual(relative.relativeOffset, -900)
        XCTAssertEqual(relative.soundName, "Glass")
        XCTAssertEqual(alarms.compactMap(\.absoluteDate), [try date("2026-07-02T09:00:00Z")])
        let place = try XCTUnwrap(alarms.first { $0.structuredLocation != nil })
        XCTAssertEqual(place.proximity, .leave)
        XCTAssertEqual(place.structuredLocation?.title, "Home")
        XCTAssertEqual(place.structuredLocation?.geoLocation?.coordinate.latitude, 40.5)
        XCTAssertEqual(place.structuredLocation?.geoLocation?.coordinate.longitude, -74)
        XCTAssertEqual(place.structuredLocation?.radius, 150)
    }

    /// The schema documents a 200 m default; the alarm used to get EventKit's
    /// own default of 0 instead.
    func testAProximityAlarmWithNoRadiusGetsTheDocumentedDefault() throws {
        let event = try standup()
        try applyEvent(
            [
                "alarms": .array([
                    .object([
                        "type": .string("proximity"), "locationTitle": .string("Home"),
                        "latitude": .double(40.5), "longitude": .int(-74),
                    ])
                ])
            ],
            to: event
        )
        let place = try XCTUnwrap(event.alarms?.first?.structuredLocation)
        XCTAssertEqual(place.radius, 200)
        XCTAssertEqual(event.alarms?.first?.proximity, .enter)
    }

    func testAnAbsoluteAlarmAcceptsADateOnlyDatetimeAsLocalMidnight() throws {
        let event = try standup()
        try applyEvent(
            ["alarms": .array([.object(["type": .string("absolute"), "datetime": .string("2026-10-05")])])],
            to: event
        )
        let localMidnight = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 5))
        XCTAssertEqual(event.alarms?.map(\.absoluteDate), [localMidnight])
    }

    func testReminderAlarmsRejectANonArrayAndNameABadEntry() {
        let reminder = milk()
        assertInputError(try applyReminder(["alarms": .int(15)], to: reminder))
        XCTAssertThrowsError(
            try applyReminder(["alarms": .array([.int(5), .string("soon")])], to: reminder)
        ) { error in
            XCTAssertEqual(
                sanitizedToolErrorMessage(for: error),
                "alarms[1]: Alarm minutes must be a whole number between -527040 and 527040"
            )
        }
        XCTAssertEqual(reminder.alarms?.map(\.relativeOffset), [-600])
    }

    func testALoneStartKeepsAOneDayAllDayEventOneDay() throws {
        let current = (start: try date("2026-10-19T00:00:00Z"), end: try date("2026-10-19T23:59:59Z"))
        let moved = try XCTUnwrap(
            try range(["start": .string("2026-10-20T09:00:00Z")], current: current, allDay: true)
        )
        XCTAssertEqual(moved.start, try date("2026-10-20T00:00:00Z"))
        XCTAssertEqual(moved.end, try date("2026-10-20T23:59:59Z"))
    }

    func testALoneStartKeepsAThreeDayAllDayEventThreeDays() throws {
        let current = (start: try date("2026-10-19T00:00:00Z"), end: try date("2026-10-21T23:59:59Z"))
        let moved = try XCTUnwrap(
            try range(["start": .string("2026-10-20T09:00:00Z")], current: current, allDay: true)
        )
        XCTAssertEqual(moved.start, try date("2026-10-20T00:00:00Z"))
        XCTAssertEqual(moved.end, try date("2026-10-22T23:59:59Z"))
    }

    /// Midnight UTC is 8 pm the day before in New York, so the event lands on
    /// the 19th there and must still be one day long.
    func testAUTCMidnightStartKeepsAnAllDayEventOneDayInAnotherZone() throws {
        let current = (start: try date("2026-10-12T04:00:00Z"), end: try date("2026-10-13T03:59:59Z"))
        let moved = try XCTUnwrap(
            try range(["start": .string("2026-10-20T00:00:00Z")], current: current, allDay: true, in: newYork)
        )
        XCTAssertEqual(moved.start, try date("2026-10-19T04:00:00Z"))
        XCTAssertEqual(moved.end, try date("2026-10-20T03:59:59Z"))
    }

    func testALoneEndStretchesAnAllDayEventToTheEndOfThatDay() throws {
        let current = (start: try date("2026-10-19T00:00:00Z"), end: try date("2026-10-19T23:59:59Z"))
        let stretched = try XCTUnwrap(
            try range(["end": .string("2026-10-21T09:00:00Z")], current: current, allDay: true)
        )
        XCTAssertEqual(stretched.start, try date("2026-10-19T00:00:00Z"))
        XCTAssertEqual(stretched.end, try date("2026-10-21T23:59:59Z"))
    }

    func testTurningAllDayOnAloneSnapsTheBoundsToWholeDays() throws {
        let event = try standup()
        try applyEvent(["isAllDay": .bool(true)], to: event)

        let local = Calendar.current
        let startOfDay = local.startOfDay(for: try date("2026-07-02T10:00:00Z"))
        XCTAssertTrue(event.isAllDay)
        XCTAssertEqual(event.startDate, startOfDay)
        XCTAssertEqual(event.endDate, local.date(bySettingHour: 23, minute: 59, second: 59, of: startOfDay))
    }

    func testTurningAllDayOnAloneYieldsWholeDayBounds() throws {
        let current = (start: try date("2026-07-02T10:00:00Z"), end: try date("2026-07-03T10:15:00Z"))
        let snapped = try XCTUnwrap(try range(["isAllDay": .bool(true)], current: current))
        XCTAssertEqual(snapped.start, try date("2026-07-02T00:00:00Z"))
        XCTAssertEqual(snapped.end, try date("2026-07-03T23:59:59Z"))

        let allDay = (start: try date("2026-07-02T00:00:00Z"), end: try date("2026-07-02T23:59:59Z"))
        XCTAssertNil(try range(["isAllDay": .bool(true)], current: allDay, allDay: true))
    }

    func testTurningAllDayOffNeedsBothBounds() throws {
        for arguments: [String: Value] in [
            ["isAllDay": .bool(false)],
            ["isAllDay": .bool(false), "start": .string("2026-07-02T10:00:00Z")],
        ] {
            let event = try standup()
            event.isAllDay = true
            XCTAssertThrowsError(try applyEvent(arguments, to: event)) { error in
                XCTAssertEqual(
                    sanitizedToolErrorMessage(for: error),
                    "start and end are required when turning all-day off"
                )
            }
            XCTAssertTrue(event.isAllDay)
        }
        let event = try standup()
        event.isAllDay = true
        try applyEvent(
            [
                "isAllDay": .bool(false),
                "start": .string("2026-07-02T10:00:00Z"),
                "end": .string("2026-07-02T11:00:00Z"),
            ],
            to: event
        )
        XCTAssertFalse(event.isAllDay)
        XCTAssertEqual(event.endDate, try date("2026-07-02T11:00:00Z"))
    }

    func testAPriorityNameIsMatchedWhateverItsCase() throws {
        let reminder = milk()
        try applyReminder(["priority": .string("Low")], to: reminder)
        XCTAssertEqual(reminder.priority, Int(EKReminderPriority.low.rawValue))
    }

    func testAnUnknownReminderPriorityIsRejected() throws {
        let reminder = milk()
        assertInputError(try applyReminder(["priority": .string("urgent")], to: reminder))
        XCTAssertEqual(reminder.priority, Int(EKReminderPriority.high.rawValue))

        try applyReminder(["priority": .string("low")], to: reminder)
        XCTAssertEqual(reminder.priority, Int(EKReminderPriority.low.rawValue))
    }

    /// An unsaved event reports its availability as not supported, so this
    /// reads the parsed field instead of the event.
    func testAnUnknownEventAvailabilityIsRejected() throws {
        assertInputError(try EventFields.update(["availability": .string("bussy")]))
        XCTAssertEqual(try EventFields.update(["availability": .string("tentative")]).availability, .tentative)
        XCTAssertNil(try EventFields.update(["availability": .null]).availability)
    }

    func testReminderFieldsOfTheWrongTypeAreRejected() {
        let wrong: [[String: Value]] = [
            ["title": .int(5)], ["title": .string("")], ["title": .string("  ")],
            ["notes": .int(7)], ["list": .int(1)], ["priority": .int(1)], ["due": .int(20_261_231)],
        ]
        for arguments in wrong {
            let reminder = milk()
            XCTAssertThrowsError(try applyReminder(arguments, to: reminder), "\(arguments)")
            XCTAssertEqual(reminder.title, "Buy milk")
            XCTAssertEqual(reminder.notes, "2%")
            XCTAssertEqual(reminder.priority, Int(EKReminderPriority.high.rawValue))
        }
    }

    func testEventFieldsOfTheWrongTypeAreRejected() throws {
        let wrong: [[String: Value]] = [
            ["title": .int(5)], ["title": .string("")], ["location": .int(5)], ["notes": .int(7)],
            ["url": .string("not a url")], ["url": .int(3)], ["isAllDay": .string("yes")],
            ["calendar": .int(5)], ["availability": .int(3)], ["start": .int(5)],
        ]
        for arguments in wrong {
            let event = try standup()
            XCTAssertThrowsError(try applyEvent(arguments, to: event), "\(arguments)")
            XCTAssertEqual(event.title, "Standup")
            XCTAssertEqual(event.location, "Room 4")
            XCTAssertNil(event.url)
            XCTAssertFalse(event.isAllDay)
        }
    }

    func testANullFieldIsReadAsAbsent() throws {
        let reminder = milk()
        try applyReminder(["title": .null, "priority": .null, "alarms": .null, "notes": .string("oat")], to: reminder)
        XCTAssertEqual(reminder.title, "Buy milk")
        XCTAssertEqual(reminder.priority, Int(EKReminderPriority.high.rawValue))
        XCTAssertEqual(reminder.alarms?.count, 1)
        XCTAssertEqual(reminder.notes, "oat")

        let event = try standup()
        try applyEvent(
            ["title": .null, "isAllDay": .null, "alarms": .null, "url": .string("https://example.com/a")],
            to: event
        )
        XCTAssertEqual(event.title, "Standup")
        XCTAssertEqual(event.alarms?.count, 1)
        XCTAssertEqual(event.url, URL(string: "https://example.com/a"))
    }

    func testEventsDeleteSpanRejectsUnknownValues() throws {
        XCTAssertEqual(try calendarEventSpan("")([:]), .thisEvent)
        XCTAssertEqual(try calendarEventSpan("")(["span": .string("thisEvent")]), .thisEvent)
        XCTAssertEqual(try calendarEventSpan("")(["span": .string("futureEvents")]), .futureEvents)
        XCTAssertThrowsError(try calendarEventSpan("")(["span": .string("allEvents")]))
        XCTAssertThrowsError(try calendarEventSpan("")(["span": .int(1)]))
    }
}
