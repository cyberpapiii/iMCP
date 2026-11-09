import AppKit
import CoreLocation
import EventKit
import Foundation
import JSONSchema
import Ontology

func allDayEventBounds(
    startDate: Date,
    endDate: Date,
    endIsDateOnly: Bool,
    calendar: Calendar = .current
) -> (start: Date, end: Date) {
    let allDayEndDate = calendar.normalizedStartDate(
        from: endDate,
        isDateOnly: endIsDateOnly
    )
    var endComponents = calendar.dateComponents([.year, .month, .day], from: allDayEndDate)
    endComponents.hour = 23
    endComponents.minute = 59
    endComponents.second = 59

    let start = calendar.startOfDay(for: startDate)
    let end =
        calendar.date(from: endComponents)
        ?? calendar.date(
            bySettingHour: 23,
            minute: 59,
            second: 59,
            of: allDayEndDate
        )
        ?? allDayEndDate

    return (start: start, end: end)
}

private let eventsFetchStart = ToolArgument<ParsedDate?>.date(
    "startDate",
    description:
        "Start date/time (defaults to now; if endDate is date-only and startDate is omitted, uses endDate's local midnight). \(ArgumentDescription.localTimeAssumed)",
    alias: "start"
)
private let eventsFetchEnd = ToolArgument<ParsedDate?>.date(
    "endDate",
    description:
        "End date/time (defaults to one week from startDate; one day if startDate is date-only). \(ArgumentDescription.localTimeAssumed)",
    alias: "end"
)
private let eventsFetchWindow = ToolArgument(properties: eventsFetchStart.properties + eventsFetchEnd.properties) {
    try calendarEventsFetchWindow(from: $0)
}

/// The week from now unless the caller says otherwise; a date-only bound
/// covers whole local days. A start that is not before the end throws.
func calendarEventsFetchWindow(
    from arguments: [String: Value],
    now: Date = Date(),
    calendar: Calendar = .current
) throws -> (start: Date, end: Date) {
    var startDate = now
    var endDate = calendar.date(byAdding: .weekOfYear, value: 1, to: now) ?? now
    let parsedStart = try eventsFetchStart(arguments)
    let parsedEnd = try eventsFetchEnd(arguments)
    var startIsDateOnly = parsedStart?.isDateOnly ?? false
    let endIsDateOnly = parsedEnd?.isDateOnly ?? false

    if let parsedStart {
        startDate = parsedStart.date
    }

    if let parsedEnd {
        endDate = parsedEnd.date
    }

    if parsedStart == nil, endIsDateOnly {
        startDate = endDate
        startIsDateOnly = true
    }

    startDate = calendar.normalizedStartDate(from: startDate, isDateOnly: startIsDateOnly)

    if endIsDateOnly {
        endDate = calendar.normalizedEndDate(from: endDate, isDateOnly: true)
    } else if parsedEnd == nil {
        if startIsDateOnly {
            endDate = calendar.normalizedEndDate(from: startDate, isDateOnly: true)
        } else if let nextWeek = calendar.date(
            byAdding: .weekOfYear,
            value: 1,
            to: startDate
        ) {
            endDate = nextWeek
        }
    }

    guard startDate < endDate else { throw ToolInputError.startNotBeforeEnd("startDate", "endDate") }
    return (start: startDate, end: endDate)
}

/// What an `events_create` or `events_update` call asked for, parsed with no
/// EventKit item touched. A nil field was not sent and is left as it was.
struct EventFields {
    let title: String?
    let isAllDay: Bool?
    let start: ParsedDate?
    let end: ParsedDate?
    let calendarName: String?
    let location: String?
    let notes: String?
    let url: URL?
    let availability: EKEventAvailability?
    let alarms: [EKAlarm]?

    private init(
        title: String?,
        isAllDay: Bool?,
        start: ParsedDate?,
        end: ParsedDate?,
        calendarName: String?,
        location: String?,
        notes: String?,
        url: URL?,
        availability: EKEventAvailability?,
        alarms: [EKAlarm]?
    ) {
        self.title = title
        self.isAllDay = isAllDay
        self.start = start
        self.end = end
        self.calendarName = calendarName
        self.location = location
        self.notes = notes
        self.url = url
        self.availability = availability
        self.alarms = alarms
    }

    static let create = fields(
        start: "Start date/time for the event. \(ArgumentDescription.localTimeAssumed) Date-only uses local midnight.",
        end: "End date/time for the event. \(ArgumentDescription.localTimeAssumed) Date-only uses local midnight.",
        calendar: "Calendar name, matched case-insensitively. Falls back to the default calendar.",
        isAllDay: .bool("isAllDay", documentedDefault: false),
        availability: .choice(
            "availability",
            description: availabilityDescription,
            among: EKEventAvailability.names,
            documentedDefault: .busy
        ),
        required: ["title", "start", "end"]
    )

    static let update = fields(
        start: "New start date/time. \(ArgumentDescription.localTimeAssumed) Date-only uses local midnight.",
        end: "New end date/time. \(ArgumentDescription.localTimeAssumed) Date-only uses local midnight.",
        calendar: "Move the event to this calendar, matched case-insensitively",
        isAllDay: .bool(
            "isAllDay",
            description: "true widens the event to whole days. false needs start and end in the same call."
        ),
        availability: .choice("availability", description: availabilityDescription, among: EKEventAvailability.names),
        required: []
    )

    private static let availabilityDescription = "How the event marks the user's time to other people"

    private static func fields(
        start startDescription: String,
        end endDescription: String,
        calendar calendarDescription: String,
        isAllDay: ToolArgument<Bool?>,
        availability: ToolArgument<EKEventAvailability?>,
        required: [String]
    ) -> ToolArgument<EventFields> {
        let title = ToolArgument<String?>.nonBlankString("title")
        let start = ToolArgument<ParsedDate?>.date("start", description: startDescription, alias: "startDate")
        let end = ToolArgument<ParsedDate?>.date("end", description: endDescription, alias: "endDate")
        let calendar = ToolArgument<String?>.string("calendar", description: calendarDescription)
        let location = ToolArgument<String?>.string("location")
        let notes = ToolArgument<String?>.string("notes")
        let url = ToolArgument<String?>.string("url", format: .uri).map { string -> URL? in
            guard let string else { return nil }
            // `URL(string:)` percent-encodes almost anything into a relative
            // URL, so only a scheme tells a link from stray text.
            guard let url = URL(string: string), url.scheme != nil else {
                throw ToolInputError("url must be a full URL with a scheme, such as https://example.com")
            }
            return url
        }
        let alarms = ToolArgument<[EKAlarm]?>("alarms", eventAlarmsSchema) { present in
            try present.map { try ArgumentValue.array($0, "alarms", eventAlarm) }
        }
        let documented: [any ToolArgumentDeclaration] = [
            title, start, end, calendar, location, notes, url, isAllDay, availability, alarms,
        ]
        return ToolArgument(properties: documented.flatMap(\.properties), required: required) { arguments in
            EventFields(
                title: try title(arguments),
                isAllDay: try isAllDay(arguments),
                start: try start(arguments),
                end: try end(arguments),
                calendarName: try calendar(arguments),
                location: try location(arguments),
                notes: try notes(arguments),
                url: try url(arguments),
                availability: try availability(arguments),
                alarms: try alarms(arguments)
            )
        }
    }

    /// The start and end the event should take, or nil when nothing the caller
    /// sent changes them.
    ///
    /// Create passes `current: nil`, which makes both bounds required. Update
    /// passes the event's own bounds: a lone `start` moves the event and keeps
    /// its length, a lone `end` changes only its length, and a lone
    /// `isAllDay: true` widens the bounds to whole days.
    func dateRange(
        current: (start: Date, end: Date, isAllDay: Bool)?,
        calendar: Calendar = .current
    ) throws -> (start: Date, end: Date)? {
        let isAllDay = self.isAllDay ?? current?.isAllDay ?? false
        if let current, start == nil, end == nil, isAllDay == current.isAllDay { return nil }
        // A whole day carries no clock times to fall back on.
        if let current, current.isAllDay, !isAllDay, start == nil || end == nil {
            throw ToolInputError("start and end are required when turning all-day off")
        }

        guard let rawStart = start?.date ?? current?.start else {
            throw ToolInputError("Event start and end are required")
        }
        let newStart = calendar.normalizedStartDate(from: rawStart, isDateOnly: start?.isDateOnly ?? false)

        // A lone new start keeps the event's length. An all-day event's length
        // is a count of days: adding its seconds to a start that is not at
        // midnight would spill into one day more.
        let rawEnd: Date
        if let end {
            rawEnd = end.date
        } else if let current, isAllDay {
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: current.start),
                to: calendar.startOfDay(for: current.end)
            ).day
            let firstDay = calendar.startOfDay(for: newStart)
            rawEnd = calendar.date(byAdding: .day, value: days ?? 0, to: firstDay) ?? firstDay
        } else if let current {
            rawEnd = newStart.addingTimeInterval(current.end.timeIntervalSince(current.start))
        } else {
            throw ToolInputError("Event start and end are required")
        }
        let endIsDateOnly = end?.isDateOnly ?? false

        // An all-day event has to span whole local days, so its bounds come from
        // the raw end date rather than the normalized one.
        let range =
            isAllDay
            ? allDayEventBounds(startDate: newStart, endDate: rawEnd, endIsDateOnly: endIsDateOnly, calendar: calendar)
            : (start: newStart, end: calendar.normalizedEndDate(from: rawEnd, isDateOnly: endIsDateOnly))

        guard range.start <= range.end else {
            throw ToolInputError("Event start must not be after its end")
        }
        return range
    }

    /// Everything that can still fail runs before the first assignment, so a
    /// throw leaves the event exactly as it was.
    func apply(to event: EKEvent, in store: EKEventStore) throws {
        let calendar = try calendarName.map { try EventKitEntity.events.editableContainer(named: $0, in: store) }
        // A new EKEvent has no dates yet; an existing one always has both.
        let current: (start: Date, end: Date, isAllDay: Bool)? =
            if let start = event.startDate, let end = event.endDate { (start, end, event.isAllDay) } else { nil }
        let range = try dateRange(current: current)

        if let title { event.title = title }
        if let isAllDay { event.isAllDay = isAllDay }
        if let range {
            event.startDate = range.start
            event.endDate = range.end
        }
        if let calendar { event.calendar = calendar }
        if let location { event.location = location }
        if let notes { event.notes = notes }
        if let url { event.url = url }
        if let availability { event.availability = availability }
        if let alarms { event.alarms = alarms }
    }
}

/// The keys an alarm object takes, each with its schema and its reader.
private enum AlarmArgument {
    static let defaultRadius = 200

    static let minutes = ToolArgument<TimeInterval>(
        "minutes",
        .integer(description: "Minutes before the event start to fire; a negative value fires after the start"),
        isRequired: true
    ) { present in
        guard let present else { throw ToolInputError("minutes is required") }
        return try alarmRelativeOffset(minutes: present)
    }
    static let datetime = ToolArgument<ParsedDate?>.date(
        "datetime",
        description: "Alarm date/time. \(ArgumentDescription.localTimeAssumed) Date-only uses local midnight.",
        isRequired: true
    ).map { parsed -> ParsedDate in
        guard let parsed else { throw ToolInputError("datetime is required") }
        return parsed
    }
    static let proximity = ToolArgument<EKAlarmProximity>.choice(
        "proximity",
        description: "Fire on arriving at or leaving the location",
        among: EKAlarmProximity.names,
        default: .defaultForAlarm
    )
    static let locationTitle = ToolArgument<String>("locationTitle", .string(), isRequired: true) { present in
        guard let present else { throw ToolInputError("locationTitle is required") }
        return try ArgumentValue.string(present, "locationTitle")
    }
    static let coordinate = ToolArgument.coordinate()
    static let radius = ToolArgument<Double>(
        "radius",
        .number(
            description: "Distance from the location, in meters, that counts as arrival",
            default: .int(defaultRadius)
        )
    ) { present in
        guard let present else { return Double(defaultRadius) }
        guard let meters = present.numberValue, meters > 0, meters.isFinite else {
            throw ToolInputError("radius must be a number of meters above 0")
        }
        return meters
    }
    static let sound = ToolArgument<Sound?>.choice(
        "sound",
        description: "Sound name to play when alarm triggers",
        among: NamedCases<Sound>()
    )
    static let emailAddress = ToolArgument<String?>.text(
        "emailAddress",
        description: "Email address to send notification to"
    )
}

/// One `type` of alarm: the keys its object takes besides `type`, `sound`,
/// and `emailAddress`, and the alarm they make.
private struct AlarmType: Sendable {
    let name: String
    let arguments: [any ToolArgumentDeclaration]
    let make: @Sendable ([String: Value]) throws -> EKAlarm

    var schema: JSONSchema {
        let type = ToolArgument<Void>(properties: [("type", .string(const: .string(name)))]) { _ in }
        return Tool.inputSchema([type] + arguments + [AlarmArgument.sound, AlarmArgument.emailAddress])
    }

    static let all = [
        AlarmType(name: "relative", arguments: [AlarmArgument.minutes]) { config in
            EKAlarm(relativeOffset: try AlarmArgument.minutes(config))
        },
        AlarmType(name: "absolute", arguments: [AlarmArgument.datetime]) { config in
            EKAlarm(absoluteDate: try AlarmArgument.datetime(config).asStart())
        },
        AlarmType(
            name: "proximity",
            arguments: [
                AlarmArgument.proximity, AlarmArgument.locationTitle, AlarmArgument.coordinate, AlarmArgument.radius,
            ]
        ) { config in
            let location = EKStructuredLocation(title: try AlarmArgument.locationTitle(config))
            let coordinate = try AlarmArgument.coordinate(config)
            location.geoLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            location.radius = try AlarmArgument.radius(config)
            let alarm = EKAlarm()
            alarm.proximity = try AlarmArgument.proximity(config)
            alarm.structuredLocation = location
            return alarm
        },
    ]
}

/// One entry of an event's `alarms` array. An entry that does not describe an
/// alarm throws: skipping it would replace the event's alarms with fewer than
/// the caller listed, or with none.
private func eventAlarm(from entry: Value) throws -> EKAlarm {
    guard case .object(let config) = entry else {
        throw ToolInputError("must be an object")
    }
    let typeName = try ArgumentValue.optional(config, "type", ArgumentValue.string) ?? "relative"
    guard let type = AlarmType.all.first(where: { $0.name == typeName }) else {
        throw ToolInputError("unknown type \"\(typeName)\". Expected relative, absolute, or proximity.")
    }
    let alarm = try type.make(config)
    if let sound = try AlarmArgument.sound(config) {
        alarm.soundName = sound.rawValue
    }
    if let email = try AlarmArgument.emailAddress(config) {
        alarm.emailAddress = email
    }
    return alarm
}

/// An unknown span is rejected rather than read as `thisEvent`, so a typo
/// cannot quietly change or delete less (or more) than the caller meant.
func calendarEventSpan(_ description: String) -> ToolArgument<EKSpan> {
    .choice(
        "span",
        description: description,
        among: NamedCases([("thisEvent", .thisEvent), ("futureEvents", .futureEvents)]),
        default: .thisEvent
    )
}

private let eventAlarmsSchema: JSONSchema = .array(
    description:
        "Alarms for the event. On update this replaces every existing alarm. Each one is relative to the start, at an absolute time, or tied to a place.",
    items: .anyOf(AlarmType.all.map(\.schema))
)

final class CalendarService: Service {
    private let access = EventKitAccess(entity: .events, store: EKEventStore())
    private var eventStore: EKEventStore { access.store }

    static let shared = CalendarService()

    var permission: ServicePermission { .eventKit(.events) }

    var isActivated: Bool {
        get async { access.isGranted }
    }

    func activate() async throws {
        try await access.activate()
    }

    /// Every occurrence of a recurring event shares one identifier, and
    /// `event(withIdentifier:)` always resolves it to the first one. With a
    /// start date, refetch that exact occurrence so `thisEvent` touches the
    /// right one and `futureEvents` starts from it, not from the whole series.
    /// `startKey` is the caller's name for the selector, used in messages.
    private func event(
        identifier: String,
        occurrenceStart parsedStart: ParsedDate?,
        startKey: String
    ) throws -> EKEvent {
        guard let anyOccurrence = eventStore.event(withIdentifier: identifier) else {
            throw ToolInputError("No event found with that identifier")
        }
        if let parsedStart {
            let startDate = parsedStart.asStart()
            let predicate = eventStore.predicateForEvents(
                withStart: startDate,
                end: startDate.addingTimeInterval(1),
                calendars: nil
            )
            guard
                let occurrence = eventStore.events(matching: predicate).first(where: {
                    $0.eventIdentifier == identifier
                        && abs($0.startDate.timeIntervalSince(startDate)) < 1
                })
            else {
                throw ToolInputError("No occurrence of that event starts at the given \(startKey)")
            }
            return occurrence
        }
        if anyOccurrence.hasRecurrenceRules {
            throw ToolInputError(
                "That event is recurring. Pass \(startKey) with the start date of the occurrence."
            )
        }
        return anyOccurrence
    }

    /// Read by `itemsMatchingRequestedNames`, which rejects a name that
    /// matches no calendar.
    private static let calendars = ToolArgument<[String]?>.strings(
        "calendars",
        description: "Names of calendars to fetch from; if empty, fetches from all calendars"
    )
    private static let query = ToolArgument.searchTerm(
        "Keep only events whose title or location contains this text"
    )
    private static let includeAllDay = ToolArgument.bool("includeAllDay", default: true)
    private static let status = ToolArgument.choice(
        "status",
        description: "Filter by event status",
        among: EKEventStatus.names
    )
    private static let availability = ToolArgument.choice(
        "availability",
        description: "Filter by availability status",
        among: EKEventAvailability.names
    )
    private static let hasAlarms = ToolArgument<Bool?>.bool("hasAlarms")
    private static let isRecurring = ToolArgument<Bool?>.bool("isRecurring")
    private static let limit = ToolArgument.limit("Maximum number of events to return", default: ListLimit.max)

    private static let identifier = ToolArgument.required(
        "identifier",
        description: "Identifier of the event: the @id value events_fetch returns"
    )
    private static let occurrenceStart = ToolArgument<ParsedDate?>.date(
        "occurrenceStart",
        description:
            "Current start date/time of the occurrence to edit. Required for recurring events, since every occurrence shares one identifier."
    )
    private static let updateSpan = calendarEventSpan(
        "For recurring events: change only this occurrence, or this and all future ones"
    )
    private static let identifierToDelete = ToolArgument.required(
        "identifier",
        description: "Identifier of the event to delete: the @id value events_fetch returns"
    )
    private static let occurrenceToDelete = ToolArgument<ParsedDate?>.date(
        "start",
        description:
            "Start date/time of the occurrence to delete. Required for recurring events, since every occurrence shares one identifier."
    )
    private static let deleteSpan = calendarEventSpan(
        "For recurring events: delete only this occurrence, or this and all future ones"
    )

    var tools: [Tool] {
        Tool(
            name: "calendars_list",
            description:
                "List the user's calendars with title, source, color, and whether each is editable or subscribed",
            arguments: [],
            annotations: .init(
                title: "List Calendars",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let calendars = self.eventStore.calendars(for: .event)

            return calendars.map(\.serviceListValue)
        }

        Tool(
            name: "events_fetch",
            description:
                "Return calendar events overlapping a date range. Defaults to the week starting now.",
            arguments: [
                eventsFetchWindow, Self.calendars, Self.query, Self.includeAllDay, Self.status, Self.availability,
                Self.hasAlarms, Self.isRecurring, Self.limit,
            ],
            annotations: .init(
                title: "Fetch Events",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let calendars = try EventKitEntity.events.itemsMatchingRequestedNames(
                self.eventStore.calendars(for: .event),
                names: try Self.calendars(arguments),
                title: \.title
            )

            let window = try eventsFetchWindow(arguments)
            let startDate = window.start
            let endDate = window.end

            let predicate = self.eventStore.predicateForEvents(
                withStart: startDate,
                end: endDate,
                calendars: calendars
            )

            // EventKit's predicate only covers the date range and calendars, so the rest of
            // the filters run here, over the fetched events.
            var events = self.eventStore.events(matching: predicate)

            if try !Self.includeAllDay(arguments) {
                events = events.filter { !$0.isAllDay }
            }

            if let searchText = try Self.query(arguments) {
                events = events.filter {
                    ($0.title?.localizedCaseInsensitiveContains(searchText) == true)
                        || ($0.location?.localizedCaseInsensitiveContains(searchText) == true)
                }
            }

            if let status = try Self.status(arguments) {
                events = events.filter { $0.status == status }
            }

            if let availability = try Self.availability(arguments) {
                events = events.filter { $0.availability == availability }
            }

            if let hasAlarms = try Self.hasAlarms(arguments) {
                events = events.filter { $0.hasAlarms == hasAlarms }
            }

            if let isRecurring = try Self.isRecurring(arguments) {
                events = events.filter { $0.hasRecurrenceRules == isRecurring }
            }

            let limit = try Self.limit(arguments)
            return events.prefix(limit).map(Event.identified)
        }
        Tool(
            name: "events_create",
            description: "Create a calendar event and return the saved event",
            arguments: [EventFields.create],
            annotations: .init(
                title: "Create Event",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let fields = try EventFields.create(arguments)
            guard fields.title != nil else {
                throw ToolInputError("Event title is required")
            }
            let event = EKEvent(eventStore: self.eventStore)
            event.calendar = self.eventStore.defaultCalendarForNewEvents
            try discardingChangesOnFailure(to: event) {
                try fields.apply(to: event, in: self.eventStore)
                try self.eventStore.save(event, span: .thisEvent)
            }

            return Event.identified(event)
        }

        Tool(
            name: "events_update",
            description:
                "Edit a calendar event by identifier and return the saved event. Only the fields you pass change; everything else, including attendees, is left as it is. Pass start alone to move the event and keep its length. For a recurring event, pass occurrenceStart to pick the occurrence.",
            arguments: [Self.identifier, Self.occurrenceStart, Self.updateSpan, EventFields.update],
            annotations: .init(
                title: "Update Event",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let identifier = try Self.identifier(arguments)
            let span = try Self.updateSpan(arguments)
            let fields = try EventFields.update(arguments)
            let event = try self.event(
                identifier: identifier,
                occurrenceStart: try Self.occurrenceStart(arguments),
                startKey: "occurrenceStart"
            )
            try discardingChangesOnFailure(to: event) {
                try fields.apply(to: event, in: self.eventStore)
                try self.eventStore.save(event, span: span, commit: true)
            }

            return Event.identified(event)
        }

        Tool(
            name: "events_delete",
            description:
                "Delete a calendar event by identifier. For a recurring event, pass the start date of the occurrence to delete.",
            arguments: [Self.identifierToDelete, Self.occurrenceToDelete, Self.deleteSpan],
            annotations: .init(
                title: "Delete Event",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let identifier = try Self.identifierToDelete(arguments)
            let span = try Self.deleteSpan(arguments)
            let event = try self.event(
                identifier: identifier,
                occurrenceStart: try Self.occurrenceToDelete(arguments),
                startKey: "start"
            )

            try self.eventStore.remove(event, span: span, commit: true)

            return Value.object([
                "deleted": .bool(true),
                "identifier": .string(identifier),
            ])
        }
    }
}

extension Event {
    /// Ontology leaves `@id` unset, and without it a fetched event cannot be
    /// handed to `events_delete`.
    fileprivate static func identified(_ event: EKEvent) -> Event {
        var result = Event(event)
        result.identifier = event.eventIdentifier
        return result
    }
}
