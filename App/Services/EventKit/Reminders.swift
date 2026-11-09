import EventKit
import Foundation
import Ontology

final class RemindersService: Service {
    private let access = EventKitAccess(entity: .reminders, store: EKEventStore())
    private var eventStore: EKEventStore { access.store }

    static let shared = RemindersService()

    var permission: ServicePermission { .eventKit(.reminders) }

    var isActivated: Bool {
        get async { access.isGranted }
    }

    func activate() async throws {
        try await access.activate()
    }

    private static let completed = ToolArgument<Bool?>.bool(
        "completed",
        description: "Fetch completed reminders instead of incomplete ones"
    ).map { $0 == true }
    private static let window = ToolArgument.dateWindow(
        "Earliest due date, or completion date when completed is true. \(ArgumentDescription.localTimeAssumed) Date-only uses local midnight.",
        "Latest due date, or completion date when completed is true. \(ArgumentDescription.localTimeAssumed) Date-only uses local midnight."
    )
    /// Read by `itemsMatchingRequestedNames`, which rejects a name that
    /// matches no list.
    private static let lists = ToolArgument<[String]?>.strings(
        "lists",
        description: "Names of reminder lists to fetch from; if empty, fetches from all lists"
    )
    private static let query = ToolArgument.searchTerm(
        "Keep only reminders whose title contains this text"
    )
    private static let limit = ToolArgument.limit("Maximum number of reminders to return", default: 100)

    var tools: [Tool] {
        Tool(
            name: "reminders_lists",
            description:
                "List the user's reminder lists with title, source, color, and whether each is editable or subscribed",
            arguments: [],
            annotations: .init(
                title: "List Reminder Lists",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let reminderLists = self.eventStore.calendars(for: .reminder)

            return reminderLists.map(\.serviceListValue)
        }

        Tool(
            name: "reminders_fetch",
            description: "Return reminders, incomplete ones unless completed is set to true",
            arguments: [Self.completed, Self.window, Self.lists, Self.query, Self.limit],
            annotations: .init(
                title: "Fetch Reminders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let reminderLists = try EventKitEntity.reminders.itemsMatchingRequestedNames(
                self.eventStore.calendars(for: .reminder),
                names: try Self.lists(arguments),
                title: \.title
            )
            let window = try Self.window(arguments)
            let startDate = window.start
            let endDate = window.end
            let limit = try Self.limit(arguments)

            let predicate: NSPredicate
            if try Self.completed(arguments) {
                predicate = self.eventStore.predicateForCompletedReminders(
                    withCompletionDateStarting: startDate,
                    ending: endDate,
                    calendars: reminderLists
                )
            } else {
                predicate = self.eventStore.predicateForIncompleteReminders(
                    withDueDateStarting: startDate,
                    ending: endDate,
                    calendars: reminderLists
                )
            }

            let reminders = try await withCheckedThrowingContinuation { continuation in
                self.eventStore.fetchReminders(matching: predicate) { fetched in
                    continuation.resume(with: remindersFetchResult(fetched))
                }
            }

            var filteredReminders = reminders

            if let searchText = try Self.query(arguments) {
                filteredReminders = filteredReminders.filter {
                    $0.title?.localizedCaseInsensitiveContains(searchText) == true
                }
            }

            return filteredReminders.prefix(limit).map { PlanAction($0) }
        }

        Tool(
            name: "reminders_create",
            description: "Create a reminder and return the saved reminder",
            arguments: [ReminderFields.create],
            annotations: .init(
                title: "Create Reminder",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let fields = try ReminderFields.create(arguments)
            guard fields.title != nil else {
                throw ToolInputError("Reminder title is required")
            }
            let reminder = EKReminder(eventStore: self.eventStore)
            reminder.calendar = self.eventStore.defaultCalendarForNewReminders()
            try discardingChangesOnFailure(to: reminder) {
                try fields.apply(to: reminder, in: self.eventStore)
                try self.eventStore.save(reminder, commit: true)
            }

            return PlanAction(reminder)
        }

        Tool(
            name: "reminders_update",
            description:
                "Edit or complete a reminder by identifier and return the saved reminder. Only the fields you pass change; everything else is left as it is. Pass completed: true to tick it off.",
            arguments: [reminderIdentifier, ReminderFields.update],
            annotations: .init(
                title: "Update Reminder",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let fields = try ReminderFields.update(arguments)
            let reminder = try requireReminder(reminderIdentifier, arguments, in: self.eventStore)
            try discardingChangesOnFailure(to: reminder) {
                try fields.apply(to: reminder, in: self.eventStore)
                try self.eventStore.save(reminder, commit: true)
            }

            return PlanAction(reminder)
        }

        Tool(
            name: "reminders_delete",
            description:
                "Delete one reminder by identifier and report its identifier and title. This removes the reminder for good; iMCP cannot undo it. A repeating reminder is deleted whole, with every future repeat: a single occurrence cannot be deleted. To tick a reminder off and keep it, use reminders_update with completed: true.",
            arguments: [reminderToDelete],
            annotations: .init(
                title: "Delete Reminder",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let reminder = try requireReminder(reminderToDelete, arguments, in: self.eventStore)
            // Read before removing: a removed item is no longer tied to the store.
            let deleted = Value.object([
                "deleted": .bool(true),
                "identifier": .string(reminder.calendarItemIdentifier),
                "title": .string(reminder.title ?? ""),
            ])

            try self.eventStore.remove(reminder, commit: true)

            return deleted
        }
    }
}

/// What a `reminders_create` or `reminders_update` call asked for, parsed with
/// no EventKit item touched. A nil field was not sent and is left as it was.
struct ReminderFields {
    let title: String?
    let listName: String?
    let due: ParsedDate?
    let notes: String?
    let priority: EKReminderPriority?
    let alarmOffsets: [TimeInterval]?
    let isCompleted: Bool?

    private init(
        title: String?,
        listName: String?,
        due: ParsedDate?,
        notes: String?,
        priority: EKReminderPriority?,
        alarmOffsets: [TimeInterval]?,
        isCompleted: Bool?
    ) {
        self.title = title
        self.listName = listName
        self.due = due
        self.notes = notes
        self.priority = priority
        self.alarmOffsets = alarmOffsets
        self.isCompleted = isCompleted
    }

    static let create = fields(
        due: "Due date/time for the reminder. \(ArgumentDescription.localTimeAssumed) Date-only uses local midnight.",
        list: "Reminder list name, matched case-insensitively. Falls back to the default list.",
        priority: ToolArgument.choice(
            "priority",
            among: EKReminderPriority.names,
            documentedDefault: EKReminderPriority.none
        ),
        alarms: "Minutes before the due date to fire each alarm",
        completed: nil,
        required: ["title"]
    )

    static let update = fields(
        due: "New due date/time. \(ArgumentDescription.localTimeAssumed) Date-only uses local midnight.",
        list: "Move the reminder to this list, matched case-insensitively",
        priority: ToolArgument.choice("priority", among: EKReminderPriority.names),
        alarms:
            "Minutes before the due date to fire each alarm. Replaces every existing alarm; an empty array removes them all.",
        completed: "true marks the reminder done; false reopens it",
        required: []
    )

    /// `completed` nil leaves the field out of the schema and out of what is
    /// read, so an undocumented key cannot change the reminder.
    private static func fields(
        due dueDescription: String,
        list listDescription: String,
        priority: ToolArgument<EKReminderPriority?>,
        alarms alarmsDescription: String,
        completed completedDescription: String?,
        required: [String]
    ) -> ToolArgument<ReminderFields> {
        let title = ToolArgument<String?>.nonBlankString("title")
        let list = ToolArgument<String?>.string("list", description: listDescription)
        let due = ToolArgument<ParsedDate?>.date("due", description: dueDescription)
        let notes = ToolArgument<String?>.string("notes")
        let alarms = ToolArgument<[TimeInterval]?>.array(
            "alarms",
            description: alarmsDescription,
            items: .integer()
        ) { try alarmRelativeOffset(minutes: $0) }
        let completed = completedDescription.map { ToolArgument<Bool?>.bool("completed", description: $0) }
        let documented: [any ToolArgumentDeclaration] =
            [title, due, list, notes, priority, alarms] + (completed.map { [$0] } ?? [])
        return ToolArgument(properties: documented.flatMap(\.properties), required: required) { arguments in
            ReminderFields(
                title: try title(arguments),
                listName: try list(arguments),
                due: try due(arguments),
                notes: try notes(arguments),
                priority: try priority(arguments),
                alarmOffsets: try alarms(arguments),
                isCompleted: try completed?(arguments) ?? nil
            )
        }
    }

    /// The list lookup is the one step that can still fail, and it runs before
    /// the first assignment, so a throw leaves the reminder exactly as it was.
    func apply(to reminder: EKReminder, in store: EKEventStore) throws {
        let list = try listName.map { try EventKitEntity.reminders.editableContainer(named: $0, in: store) }

        if let title { reminder.title = title }
        if let list { reminder.calendar = list }
        if let due {
            let calendar = Calendar.current
            reminder.dueDateComponents = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: calendar.normalizedStartDate(from: due.date, isDateOnly: due.isDateOnly)
            )
        }
        if let notes { reminder.notes = notes }
        if let priority { reminder.priority = Int(priority.rawValue) }
        if let alarmOffsets { reminder.alarms = alarmOffsets.map { EKAlarm(relativeOffset: $0) } }
        if let isCompleted { reminder.isCompleted = isCompleted }
    }
}

let reminderIdentifier = ToolArgument.required(
    "identifier",
    description: "Identifier of the reminder: the @id value from a recent reminders_fetch"
)
/// The same key, described for deleting.
private let reminderToDelete = ToolArgument.required(
    "identifier",
    description: "Identifier of the reminder to delete: the @id value from a recent reminders_fetch"
)

/// `fetchReminders` hands back nil when the fetch itself failed.
func remindersFetchResult(_ fetched: [EKReminder]?) -> Result<[EKReminder], any Error> {
    fetched.map { .success($0) } ?? .failure(ToolFailure("Reminders fetch failed"))
}

/// The one reminder the caller named through `argument`, the one the tool
/// declared. An identifier that matches nothing is the caller's to fix, so
/// this throws instead of returning nil.
func requireReminder(
    _ argument: ToolArgument<String>,
    _ arguments: [String: Value],
    in store: EKEventStore
) throws -> EKReminder {
    let identifier = try argument(arguments)
    guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
        throw ToolInputError(
            "No reminder found with that identifier. Call reminders_fetch for current identifiers."
        )
    }
    return reminder
}
