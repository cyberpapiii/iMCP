import EventKit
import MapKit
import JSONSchema
import XCTest

@testable import iMCP

/// The shared argument kinds: one value gives both the schema a client reads
/// and the parser the tool runs.
final class ToolArgumentTests: XCTestCase {
    private let formatter = ISO8601DateFormatter()

    func testADateWindowParsesIndependentBounds() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(86_400)
        let window = try ToolArgument.dateWindow()([
            "startDate": .string(formatter.string(from: start)),
            "endDate": .string(formatter.string(from: end)),
        ])
        XCTAssertEqual(try XCTUnwrap(window.start).timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(window.end).timeIntervalSince1970, end.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try ToolArgument.dateWindow()([:]), DateWindow(start: nil, end: nil))
    }

    func testADateWindowRejectsAnInvertedRange() {
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertThrowsError(
            try ToolArgument.dateWindow()([
                "startDate": .string(formatter.string(from: end.addingTimeInterval(86_400))),
                "endDate": .string(formatter.string(from: end)),
            ])
        ) { error in
            XCTAssertEqual((error as? ToolInputError)?.message, "startDate must be earlier than endDate")
        }
    }

    /// The undocumented spelling is an explicit alias, read only when the
    /// documented key is absent.
    func testADateWindowReadsItsAliases() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let window = ToolArgument.dateWindow()
        for key in ["start", "startDate"] {
            let parsed = try window([key: .string(formatter.string(from: start))])
            XCTAssertEqual(try XCTUnwrap(parsed.start).timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 1)
        }
        XCTAssertEqual(ToolArgument.dateWindow().properties.map(\.key), ["startDate", "endDate"])
    }

    func testADateOnlyEndCoversTheWholeDay() throws {
        let calendar = Calendar.current
        let window = try ToolArgument.dateWindow()(["startDate": "2026-07-04", "endDate": "2026-07-04"])
        let day = calendar.startOfDay(
            for: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 4)))
        )
        XCTAssertEqual(window.start, day)
        XCTAssertEqual(window.end, calendar.date(byAdding: .day, value: 1, to: day))
    }

    func testAPresentUnparseableDateThrowsNamingTheKey() {
        for value: Value in ["not-a-date", "", "   ", .int(5)] {
            XCTAssertThrowsError(try ToolArgument.dateWindow()(["startDate": value])) { error in
                XCTAssertEqual(
                    (error as? ToolInputError)?.message,
                    "startDate must be an ISO 8601 date or date-time"
                )
            }
        }
    }

    func testALimitClampsIntoItsDocumentedRange() throws {
        let limit = ToolArgument.limit("")
        XCTAssertEqual(try limit([:]), ListLimit.default)
        XCTAssertEqual(try limit(["limit": .int(Int.max)]), ListLimit.max)
        XCTAssertEqual(try limit(["limit": .int(-4)]), 0)
        XCTAssertEqual(try limit(["limit": .double(25.0)]), 25)
        XCTAssertThrowsError(try limit(["limit": .string("25")])) { error in
            XCTAssertEqual((error as? ToolInputError)?.message, "limit must be a whole number")
        }
        let events = ToolArgument.limit("", default: ListLimit.max)
        XCTAssertEqual(try events([:]), 500)
        XCTAssertEqual(try events(["limit": .int(10_000)]), 500)
        XCTAssertEqual(try events(["limit": .int(12)]), 12)
    }

    /// The schema and the parser come from one value, so they cannot drift
    /// apart the way Photos' minimum 1 and its 0 floor once did.
    func testTheSchemaStatesWhatTheParserEnforces() {
        let limit = ToolArgument.limit("Maximum things", default: 30, minimum: 1, maximum: 100)
        XCTAssertEqual(limit.properties.count, 1)
        XCTAssertEqual(limit.properties[0].key, "limit")
        XCTAssertEqual(
            limit.properties[0].schema,
            .integer(description: "Maximum things", default: .int(30), minimum: 1, maximum: 100)
        )
        XCTAssertEqual(try limit(["limit": .int(0)]), 1)

        let choice = ToolArgument<ImageFormat>.choice("format", description: "Encoding", default: .png)
        XCTAssertEqual(
            choice.properties[0].schema,
            .string(description: "Encoding", default: "png", enum: ["jpeg", "png"])
        )
    }

    /// A tool's schema lists required keys in declaration order and accepts
    /// nothing it does not document.
    func testAToolSchemaJoinsItsArguments() {
        let schema = Tool.inputSchema([
            ToolArgument.required("title"),
            ToolArgument.coordinate(),
            ToolArgument.limit(""),
        ])
        guard case .object(_, _, _, _, _, _, let properties, let required, let additionalProperties) = schema else {
            return XCTFail("not an object schema")
        }
        XCTAssertEqual(Array(properties.keys), ["title", "latitude", "longitude", "limit"])
        XCTAssertEqual(required, ["title", "latitude", "longitude"])
        XCTAssertEqual(additionalProperties, .boolean(false))
    }

    func testARequiredStringRejectsMissingBlankAndWrongTyped() throws {
        let identifier = ToolArgument.required("identifier")
        XCTAssertEqual(try identifier(["identifier": "abc"]), "abc")
        let rejected: [([String: Value], String)] = [
            ([:], "identifier is required"),
            (["identifier": .null], "identifier is required"),
            (["identifier": ""], "identifier must not be empty"),
            (["identifier": "   "], "identifier must not be empty"),
            (["identifier": .int(1)], "identifier must be a string"),
        ]
        for (arguments, message) in rejected {
            XCTAssertThrowsError(try identifier(arguments)) { error in
                XCTAssertEqual((error as? ToolInputError)?.message, message)
            }
        }
    }

    func testASearchTermTreatsEmptyAsNoSearch() throws {
        XCTAssertNil(try ToolArgument.searchTerm("")(["query": ""]))
        XCTAssertEqual(try ToolArgument.searchTerm("")(["query": " a "]), " a ")
        XCTAssertNil(try ToolArgument.searchTerm("", trimmed: true)(["query": "   "]))
        XCTAssertEqual(try ToolArgument.searchTerm("", trimmed: true)(["query": " a "]), "a")
        XCTAssertThrowsError(try ToolArgument.searchTerm("")(["query": .int(5)])) { error in
            XCTAssertEqual((error as? ToolInputError)?.message, "query must be a string")
        }
    }

    /// Browser History documents its fallback; nothing else falls back.
    func testOnlyAnOptedInChoiceFallsBack() throws {
        let table = NamedCases<Browser?>([("all", nil), ("safari", .safari)])
        let lenient = ToolArgument.choice("browser", among: table, default: nil, unknownFallsBack: true)
        XCTAssertNil(try lenient(["browser": "netscape"]))
        XCTAssertEqual(try lenient(["browser": "Safari"]), .safari)
        let strict = ToolArgument.choice("browser", among: table, default: nil)
        XCTAssertThrowsError(try strict(["browser": "netscape"]))
    }

    func testADocumentedDefaultIsNotApplied() throws {
        let availability = ToolArgument.choice(
            "availability",
            among: EKEventAvailability.names,
            documentedDefault: .busy
        )
        XCTAssertNil(try availability([:]))
        guard case .string(_, _, let defaultValue, _, _, _, _, _, _, _) = availability.properties[0].schema else {
            return XCTFail("not a string schema")
        }
        XCTAssertEqual(defaultValue, "busy")
    }

    func testNumericArgumentsAcceptOnlyIntegerAndDoubleValues() {
        XCTAssertEqual(Value.int(80).numberValue, 80)
        XCTAssertEqual(Value.double(80.5).numberValue, 80.5)
        XCTAssertEqual(Value.int(Int.max).numberValue, Double(Int.max))
        for value: Value in [.string("80"), .bool(true), .null, .array([]), .object([:])] {
            XCTAssertNil(value.numberValue)
        }
    }

    func testWholeNumberValueNeverTraps() {
        XCTAssertEqual(Value.int(7).wholeNumberValue, 7)
        XCTAssertEqual(Value.double(7.0).wholeNumberValue, 7)
        let rejected: [Value] = [
            .double(7.5), .double(1e300), .double(.nan), .double(.infinity), .string("7"), .bool(true),
        ]
        for value in rejected {
            XCTAssertNil(value.wholeNumberValue)
        }
    }

    func testClampedIntArgument() throws {
        func parse(_ arguments: [String: Value]) throws -> Int {
            try ToolArgument.integer("limit", default: 30, in: 1 ... 100)(arguments)
        }
        XCTAssertEqual(try parse([:]), 30)
        XCTAssertEqual(try parse(["limit": .null]), 30)
        XCTAssertEqual(try parse(["limit": .int(12)]), 12)
        XCTAssertEqual(try parse(["limit": .double(40.0)]), 40)
        XCTAssertEqual(try parse(["limit": .int(Int.max)]), 100)
        XCTAssertEqual(try parse(["limit": .int(Int.min)]), 1)
        for value: Value in [.string("5"), .double(1e300), .double(2.5)] {
            XCTAssertThrowsError(try parse(["limit": value])) { error in
                XCTAssertTrue(error is ToolInputError)
            }
        }
    }

    func testClampedNumberArgument() throws {
        func parse(_ arguments: [String: Value]) throws -> Double {
            try ToolArgument.number("duration", default: 10, in: 1 ... 300)(arguments)
        }
        XCTAssertEqual(try parse([:]), 10)
        XCTAssertEqual(try parse(["duration": .int(-5)]), 1)
        XCTAssertEqual(try parse(["duration": .double(.infinity)]), 300)
        XCTAssertEqual(try parse(["duration": .double(2.5)]), 2.5)
        for value: Value in [.double(.nan), .string("2")] {
            XCTAssertThrowsError(try parse(["duration": value])) { error in
                XCTAssertTrue(error is ToolInputError)
            }
        }
    }

    func testEnumArgumentRejectsUnknownNames() throws {
        let format = ToolArgument<ImageFormat>.choice("format", default: .png)
        XCTAssertEqual(try format([:]), .png)
        XCTAssertEqual(try format(["format": .string("jpeg")]), .jpeg)
        XCTAssertThrowsError(try format(["format": .string("gif")])) { error in
            XCTAssertEqual(
                sanitizedToolErrorMessage(for: error),
                "Invalid format. Expected one of: jpeg, png."
            )
        }
        XCTAssertThrowsError(try format(["format": .int(1)])) { error in
            XCTAssertTrue(error is ToolInputError)
        }
    }

    func testCoordinateArgumentRejectsPointsOffTheEarth() throws {
        let point = try ToolArgument.coordinate()(["latitude": .double(37.3), "longitude": .double(-122.0)])
        XCTAssertEqual(point.latitude, 37.3)
        XCTAssertEqual(point.longitude, -122.0)

        let origin = try ToolArgument.coordinate(latitude: "originLatitude", longitude: "originLongitude")(
            ["originLatitude": .int(10), "originLongitude": .int(20)]
        )
        XCTAssertEqual(origin.latitude, 10)
        XCTAssertEqual(origin.longitude, 20)

        let rejected: [[String: Value]] = [
            ["latitude": .double(37.3)],
            ["latitude": .int(91), "longitude": .int(0)],
            ["latitude": .int(0), "longitude": .int(-181)],
            ["latitude": .double(.nan), "longitude": .int(0)],
        ]
        for arguments in rejected {
            XCTAssertThrowsError(try ToolArgument.coordinate()(arguments)) { error in
                XCTAssertTrue(error is ToolInputError)
            }
        }
    }

    /// Clients send JSON null for an optional they leave out.
    func testNullOptionalArgumentIsAbsent() throws {
        XCTAssertEqual(try ToolArgument.integer("limit", default: 30, in: 1 ... 100)(["limit": .null]), 30)
        XCTAssertEqual(try ToolArgument.number("duration", default: 10, in: 1 ... 300)(["duration": .null]), 10)
        XCTAssertEqual(try ToolArgument<ImageFormat>.choice("format", default: .png)(["format": .null]), .png)
        XCTAssertNil(try captureIdentifier("displayId", description: "")(["displayId": .null]))

        let due = ToolArgument<ParsedDate?>.date("due")
        XCTAssertNil(try due(["due": .null]))
        let start = ToolArgument<ParsedDate?>.date("start", alias: "startDate")
        XCTAssertNotNil(try start(["start": .null, "startDate": .string("2026-01-01")]))
        XCTAssertNil(try start(["start": .null, "startDate": .null]))

        let window = try ToolArgument.dateWindow()(["startDate": .null, "endDate": .null])
        XCTAssertEqual(window, DateWindow(start: nil, end: nil))
        XCTAssertEqual(try ToolArgument.limit("")(["limit": .null]), 30)

        XCTAssertThrowsError(try due(["due": .int(5)])) { error in
            XCTAssertEqual(sanitizedToolErrorMessage(for: error), "due must be an ISO 8601 date or date-time")
        }
    }

    func testNullRequiredCoordinateIsMissing() {
        XCTAssertThrowsError(try ToolArgument.coordinate()(["latitude": .null, "longitude": .double(-122.0)])) {
            error in
            XCTAssertEqual(sanitizedToolErrorMessage(for: error), "latitude and longitude are required numbers")
        }
    }

    /// Date errors name the key the caller has to fix.
    func testSanitizedMessagePassesThroughDateArgumentErrors() {
        let window = ToolArgument.dateWindow()
        XCTAssertThrowsError(try window(["startDate": "soon"])) {
            XCTAssertEqual(sanitizedToolErrorMessage(for: $0), "startDate must be an ISO 8601 date or date-time")
        }
        XCTAssertThrowsError(try window(["startDate": "2026-02-01", "endDate": "2026-01-01"])) {
            XCTAssertEqual(sanitizedToolErrorMessage(for: $0), "startDate must be earlier than endDate")
        }
    }

    /// The runtime still honours the undocumented spellings, so a client that
    /// learned them from an older tool list keeps working.
    func testUndocumentedDateSpellingsStillResolve() throws {
        let day = try XCTUnwrap(ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: "2026-01-01"))
        XCTAssertEqual(
            try ToolArgument<ParsedDate?>.date("startDate", alias: "start")(["start": .string("2026-01-01")])?.date,
            day.date
        )
        XCTAssertEqual(
            try ToolArgument<ParsedDate?>.date("start", alias: "startDate")(["startDate": .string("2026-01-01")])?.date,
            day.date
        )
        XCTAssertEqual(try ContactsService.identifier(["@id": .string("x")]), "x")
    }
}

/// Decision 6: a value of the wrong type throws instead of being dropped
/// while the call reports success. Each case runs a real tool whose
/// arguments are read before it touches any data.
final class StrictArgumentTests: XCTestCase {
    private func assertRejected(
        _ service: any Service,
        _ tool: String,
        _ arguments: [String: Value],
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let tool = try XCTUnwrap(service.tools.first { $0.name == tool }, file: file, line: line)
        do {
            _ = try await tool(arguments)
            XCTFail("accepted \(arguments)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? ToolInputError)?.message, message, file: file, line: line)
        }
    }

    func testAWrongTypedBoolThrows() async throws {
        XCTAssertThrowsError(try ToolArgument.bool("autoFocus", default: true)(["autoFocus": "false"])) { error in
            XCTAssertEqual((error as? ToolInputError)?.message, "autoFocus must be true or false")
        }
        XCTAssertNil(try ToolArgument<Bool?>.bool("isRead")(["isRead": .null]))
        try await assertRejected(
            MessageService.shared,
            "messages_fetch",
            ["isRead": "true"],
            "isRead must be true or false"
        )
        try await assertRejected(
            MessageService.shared,
            "messages_fetch",
            ["attachments": .int(1)],
            "attachments must be true or false"
        )
        try await assertRejected(
            PhotoService.shared,
            "photos_search",
            ["favorites": "yes"],
            "favorites must be true or false"
        )
    }

    /// An unknown direction used to mean any direction, and a non-string
    /// sound played the default. Only Browser History falls back, by design.
    func testAnUnknownChoiceThrows() async throws {
        try await assertRejected(
            CallHistoryService.shared,
            "calls_fetch",
            ["direction": "inbound"],
            "Invalid direction. Expected one of: incoming, outgoing, any."
        )
        try await assertRejected(
            UtilitiesService.shared,
            "utilities_beep",
            ["sound": .int(3)],
            "Invalid sound. Expected one of: Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink."
        )
        try await assertRejected(
            CalendarService.shared,
            "events_delete",
            ["identifier": "x", "span": "allEvents"],
            "Invalid span. Expected one of: thisEvent, futureEvents."
        )
    }

    /// `participants: [""]` used to lose its one blank entry and then read
    /// every conversation; a list name that is not a string was read as "".
    func testABlankOrWrongTypedListEntryThrows() async throws {
        try await assertRejected(
            MessageService.shared,
            "messages_fetch",
            ["participants": [""]],
            "participants[0]: handle must not be empty"
        )
        try await assertRejected(
            MessageService.shared,
            "messages_fetch",
            ["participants": ["+15550000000", .int(5)]],
            "participants[1]: handle must be a string"
        )
        try await assertRejected(
            MessageService.shared,
            "messages_fetch",
            ["participants": "+15550000000"],
            "participants must be an array"
        )
        XCTAssertEqual(try MessageService.participants(["participants": [" +15550000000 "]]), ["+15550000000"])
        XCTAssertEqual(try MessageService.participants([:]), [])
    }

    /// A wrong-typed point or radius used to fall back to "pass either
    /// latitude and longitude" or to 150 m; a wrong-typed route endpoint was
    /// read as missing.
    func testAWrongTypedNumberOrEndpointThrows() async throws {
        let numbers = ToolArgument<Double?>.number("latitude")
        XCTAssertEqual(try numbers(["latitude": .int(40)]), 40)
        XCTAssertThrowsError(try numbers(["latitude": "40"])) { error in
            XCTAssertEqual((error as? ToolInputError)?.message, "latitude must be a number")
        }
        try await assertRejected(
            MapsService.shared,
            "maps_directions",
            ["originAddress": .int(1), "destinationAddress": "Cupertino"],
            "originAddress must be a string"
        )
        try await assertRejected(
            MapsService.shared,
            "maps_directions",
            ["originCoordinates": "37,-122", "destinationAddress": "Cupertino"],
            "originCoordinates must be an object"
        )
    }

    /// A blank route address reached MKLocalSearch, which answered "Could not
    /// find location for address".
    func testABlankRouteAddressThrows() async throws {
        for blank: Value in ["", "   "] {
            try await assertRejected(
                MapsService.shared,
                "maps_directions",
                ["originAddress": blank, "destinationAddress": "Cupertino"],
                "originAddress must not be empty"
            )
        }
    }

    /// reminders_fetch passed an inverted window to EventKit, which answered
    /// with nothing; every other date tool already rejected one.
    func testRemindersRejectAStartAfterTheEnd() async throws {
        try await assertRejected(
            RemindersService.shared,
            "reminders_fetch",
            ["startDate": "2026-03-02", "endDate": "2026-03-01"],
            "startDate must be earlier than endDate"
        )
    }

    /// events_fetch handed a reversed range to EventKit, which answered with
    /// nothing, while every other date window rejected one.
    func testCalendarRejectsAStartAfterTheEnd() async throws {
        try await assertRejected(
            CalendarService.shared,
            "events_fetch",
            ["startDate": "2026-03-02T10:00:00Z", "endDate": "2026-03-01T10:00:00Z"],
            "startDate must be earlier than endDate"
        )
        try await assertRejected(
            CalendarService.shared,
            "events_fetch",
            ["startDate": "2026-03-02", "endDate": "2026-03-01"],
            "startDate must be earlier than endDate"
        )
    }

    /// Maps read its arguments by hand: a blank query or address reached
    /// MapKit, a non-object region meant no region, anything but `true` or an
    /// array meant no points of interest, and categories were case-sensitive.
    func testMapsArgumentsAreReadLikeEveryOtherTools() async throws {
        try await assertRejected(MapsService.shared, "maps_search", ["query": "  "], "query must not be empty")
        try await assertRejected(MapsService.shared, "maps_search", [:], "query is required")
        try await assertRejected(
            MapsService.shared,
            "maps_search",
            ["query": "coffee", "region": "Brooklyn"],
            "region must be an object"
        )
        try await assertRejected(MapsService.shared, "maps_geocode", ["address": ""], "address must not be empty")
        try await assertRejected(MapsService.shared, "maps_geocode", ["address": .int(1)], "address must be a string")
        try await assertRejected(
            MapsService.shared,
            "maps_explore",
            ["category": "café", "latitude": 40.7, "longitude": -73.9],
            "Invalid category. Expected one of: \(MKPointOfInterestCategory.names.names.joined(separator: ", "))."
        )
        try await assertRejected(
            MapsService.shared,
            "maps_explore",
            ["latitude": 40.7, "longitude": -73.9],
            "category is required"
        )
        XCTAssertEqual(
            try ToolArgument.requiredChoice("category", among: MKPointOfInterestCategory.names)(["category": "CAFE"]),
            .cafe
        )

        let map: [String: Value] = ["latitude": 40.7, "longitude": -73.9, "latitudeDelta": 0.1, "longitudeDelta": 0.1]
        try await assertRejected(
            MapsService.shared,
            "maps_generate",
            map.merging(["showPointsOfInterest": "true"]) { $1 },
            "showPointsOfInterest must be true, false, or an array of categories"
        )
        try await assertRejected(
            MapsService.shared,
            "maps_generate",
            map.merging(["showPointsOfInterest": ["cafe", "bar"]]) { $1 },
            "showPointsOfInterest[1]: Invalid category. Expected one of: "
                + "\(MKPointOfInterestCategory.names.names.joined(separator: ", "))."
        )
    }

    /// contacts_create and contacts_update skipped a wrong-typed field and
    /// reported success; contacts_search turned a blank phone into a search
    /// for an empty number.
    func testContactsArgumentsAreReadLikeEveryOtherTools() async throws {
        try await assertRejected(
            ContactsService.shared,
            "contacts_create",
            ["givenName": .int(5)],
            "givenName must be a string"
        )
        try await assertRejected(
            ContactsService.shared,
            "contacts_update",
            ["identifier": "x", "jobTitle": true],
            "jobTitle must be a string"
        )
        try await assertRejected(
            ContactsService.shared,
            "contacts_search",
            ["phone": "  "],
            "At least one valid search parameter is required"
        )
        try await assertRejected(
            ContactsService.shared,
            "contacts_search",
            ["phone": .int(5)],
            "phone must be a string"
        )
    }

    /// contacts_create saved a nameless card for a whitespace-only given name.
    func testContactsCreateRejectsABlankGivenName() async throws {
        for arguments: [String: Value] in [["givenName": "   "], ["givenName": ""], ["familyName": "Lovelace"]] {
            try await assertRejected(ContactsService.shared, "contacts_create", arguments, "Given name is required")
        }
    }

    /// reminders_create left `completed` out of its schema but still applied
    /// it; an undocumented key no longer changes the reminder.
    func testRemindersCreateDoesNotReadAnUndocumentedCompleted() throws {
        XCTAssertNil(try ReminderFields.create(["title": "Milk", "completed": true]).isCompleted)
        XCTAssertEqual(try ReminderFields.update(["completed": true]).isCompleted, true)
    }

    /// A non-string search term used to be ignored, which widened the read to
    /// everything; a non-string filter or identifier the same.
    func testAWrongTypedStringThrows() async throws {
        try await assertRejected(MessageService.shared, "messages_fetch", ["query": .int(5)], "query must be a string")
        try await assertRejected(NotesService.shared, "notes_search", ["folder": .int(5)], "folder must be a string")
        try await assertRejected(NotesService.shared, "notes_fetch", ["id": .int(5)], "id must be a string")
        try await assertRejected(NotesService.shared, "notes_fetch", ["id": "  "], "id must not be empty")
        try await assertRejected(ShortcutsService.shared, "shortcuts_run", ["name": ""], "name must not be empty")
        try await assertRejected(
            ShortcutsService.shared,
            "shortcuts_run",
            ["name": "x", "input": .int(1)],
            "input must be a string"
        )
    }
}
