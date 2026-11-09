# Plan 054: Reminders can be edited, ticked off and deleted, events can be rescheduled in place, and a named place can be deleted

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- App/Services/Reminders.swift App/Services/Calendar.swift App/Services/Location.swift App/Services/Location/LocationHistoryStore.swift iMCPTests/CallToolDispatchTests.swift iMCPTests/LocationRenewalAndTimelineTests.swift README.md`
> This plan depends on plans 038, 039 and 041, which edit the same files, so
> the diff WILL be non-empty. That is expected. What you must do is compare
> each "Current state" excerpt against the live code and apply the rule in
> "How to read the excerpts after the dependencies landed" below. A mismatch
> that rule does not explain is a STOP condition.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED (four new tools that change the user's real reminders, calendar and place list; one of them deletes reminders)
- **Depends on**: plans/038-validate-tool-arguments.md, plans/039-correct-tool-annotations.md, plans/041-contacts-update-data-loss.md
- **Category**: direction
- **Planned at**: commit `8165d29`, 2026-10-12
- **Amended**: 2026-10-12, same commit — `reminders_delete` added at the owner's request (Step 2b)

## Why this matters

iMCP exposes 52 tools and only six of them write. The writes are lopsided:
`reminders_create` exists but nothing can complete, edit or delete a
reminder, so an agent asked to "tick that off" or to clean up a cluttered
list cannot. `events_create` and `events_delete`
exist but there is no update, so rescheduling means delete plus recreate,
which drops attendees and loses the event's identity. `location_place_set`
exists and the store already has `deletePlace(named:)`, but only the Location
window can call it. This plan adds exactly four tools (`reminders_update`,
`reminders_delete`, `events_update`, `location_place_delete`), taking the
total from 52 to 56. It gets the two update tools by moving the create
handlers' field-setting code into one shared function per service, so create
and update cannot drift apart. `reminders_delete` removes exactly one
reminder per call, by identifier, and reuses the lookup `reminders_update`
needs anyway. No new types, no new files.

## Current state

All line numbers are from commit `8165d29`.

### How to read the excerpts after the dependencies landed

Plans 038, 039 and 041 land before this one and change lines inside the
excerpts below. The rule:

- Where this plan says **"move verbatim"**, move the code as it exists in the
  live file when you start, including whatever 038 changed (for example a
  bounded alarm-minutes helper in place of `TimeInterval(-minutes * 60)`, or a
  throwing date parser in place of the silent `if case ... let parsed`). Do not
  revert 038's changes back to the excerpt.
- The excerpts are for locating the code and confirming its shape. A live
  block that sits at the same place, does the same job, and differs only in the
  ways the three dependency plans describe is a match.
- If a block named here is missing, has moved to another file, or has already
  been extracted into a function, that is a STOP condition.

### Files and roles

- `App/Services/Reminders.swift` (271 lines) — `RemindersService`. Tools
  `reminders_lists` (line 29), `reminders_fetch` (50), `reminders_create`
  (152). Also holds two free helpers used by Calendar too:
  `requireEventKitFetchResults` (242) and `requireSingleCalendar` (257).
- `App/Services/Calendar.swift` (643 lines) — `CalendarService`. Free helpers
  at the top (`allDayEventBounds` line 10, `calendarEventsFetchWindow` 40,
  `calendarEventsDeleteSpan` 89, `calendarEventsFetchLimit` 101). Tools
  `calendars_list` (129), `events_fetch` (150), `events_create` (261),
  `events_delete` (543). `Event.identified` at 635-643.
- `App/Services/Location.swift` (1449 lines) — `LocationService`.
  `location_places` at 667, `location_place_set` at 687-757; it is the last
  tool in the `tools` builder, which closes at line 758.
- `App/Services/Location/LocationHistoryStore.swift` — SQLite store actor.
  `setPlace` 424-479, `deletePlace(named:)` 481-494.
- `App/Views/LocationWindow.swift:405-412` — the only caller of
  `deletePlace(named:)` today.
- `App/Models/FetchPolicy.swift:31-61` — `dateString(from:primary:)` and
  `parseRawDate(_:)`, the existing throwing date parsers.
- `App/Controllers/ToolErrorResponse.swift` — `ClientFacingError` and
  `ToolInputError`. An error reaches the MCP client verbatim only if it
  conforms to `ClientFacingError`; anything else becomes "Tool execution
  failed. See iMCP logs for details." Bad arguments throw
  `ToolInputError("...")`.
- `iMCPTests/CallToolDispatchTests.swift` — already imports EventKit; holds
  `CallToolDispatchTests` (line 6) and `ToolSchemaHygieneTests` (line 89),
  including `testEventsDeleteSpanRejectsUnknownValues` (127-133). After plan
  039 it also ends with `ToolAnnotationTests`, whose `table` string has one
  row per tool (`<tool_name> <read|add|destroy> <local|open>`, sorted by
  name) and whose test fails if the set of rows differs from the set of
  registered tools. Adding a tool without adding its row fails that test.
- `iMCPTests/LocationRenewalAndTimelineTests.swift` — `LocationTimelineToolTests`
  (line 262) builds a `LocationService` over a temp-directory SQLite store and
  calls tools by name; `testAWholeNumberRadiusIsHonoured` (430) is the
  exemplar for a place tool test.

### Identifiers the fetch tools return

- `reminders_fetch` returns `PlanAction($0)` (`Reminders.swift:148`). In the
  pinned Ontology package (0.10.0) that initialiser sets
  `identifier = reminder.calendarItemIdentifier` and encodes it as `@id`. So a
  reminder's `@id` is its `calendarItemIdentifier`, and
  `EKEventStore.calendarItem(withIdentifier:)` resolves it. Apple documents
  that this identifier is stable on the device but can change after a full
  sync of the account; the tool description must tell the caller to take the
  `@id` from a recent `reminders_fetch`. `reminders_update` and
  `reminders_delete` both take this value as `identifier`.
  `calendarItem(withIdentifier:)` returns an `EKCalendarItem`, which may be
  an event; the `as? EKReminder` cast is what stops an event's identifier
  from resolving here.
- `events_fetch` returns `Event.identified` (`Calendar.swift:635-643`), whose
  `@id` is `event.eventIdentifier`. Every occurrence of a recurring event
  shares that identifier.

### `reminders_create` handler today (`Reminders.swift:184-239`)

```swift
        ) { arguments in
            try await self.activate()

            let reminder = EKReminder(eventStore: self.eventStore)

            guard case .string(let title) = arguments["title"] else {
                throw ToolInputError("Reminder title is required")
            }
            reminder.title = title

            var calendar = self.eventStore.defaultCalendarForNewReminders()
            if case .string(let listName) = arguments["list"] {
                calendar = try requireSingleCalendar(
                    self.eventStore.editableCalendars(named: listName, for: .reminder),
                    named: listName,
                    kind: "Reminder list",
                    listTool: "reminders_lists"
                )
            }
            reminder.calendar = calendar

            if case .string(let dueDateStr) = arguments["due"],
                let parsedDueDate = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: dueDateStr
                )
            {
                let calendar = Calendar.current
                let dueDate = calendar.normalizedStartDate(
                    from: parsedDueDate.date,
                    isDateOnly: parsedDueDate.isDateOnly
                )
                reminder.dueDateComponents = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: dueDate
                )
            }

            if case .string(let notes) = arguments["notes"] {
                reminder.notes = notes
            }

            if case .string(let priorityStr) = arguments["priority"] {
                reminder.priority = Int(EKReminderPriority.from(string: priorityStr).rawValue)
            }

            if case .array(let alarmMinutes) = arguments["alarms"] {
                reminder.alarms = alarmMinutes.compactMap {
                    guard case .int(let minutes) = $0 else { return nil }
                    return EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                }
            }

            try self.eventStore.save(reminder, commit: true)

            return PlanAction(reminder)
        }
```

Every field after `title` is already "set only if supplied". That is exactly
the partial-update contract, which is why one shared function serves both
create and update.

### `events_create` handler today (`Calendar.swift:380-540`)

Shape, abbreviated (the alarms loop at 459-535 is 77 lines and is moved, not
retyped):

```swift
        ) { arguments in
            try await self.activate()

            let event = EKEvent(eventStore: self.eventStore)

            guard case .string(let title) = arguments["title"] else {
                throw ToolInputError("Event title is required")
            }
            event.title = title

            guard case .string(let startDateStr) = arguments["start"],
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: startDateStr
                ),
                case .string(let endDateStr) = arguments["end"],
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: endDateStr
                )
            else {
                throw ToolInputError("Invalid start or end date format. Expected ISO 8601 format.")
            }

            let calendar = Calendar.current
            let startDate = calendar.normalizedStartDate(from: parsedStart.date, isDateOnly: parsedStart.isDateOnly)
            let endDate = calendar.normalizedEndDate(from: parsedEnd.date, isDateOnly: parsedEnd.isDateOnly)

            if case .bool(true) = arguments["isAllDay"] {
                let bounds = allDayEventBounds(
                    startDate: startDate,
                    endDate: parsedEnd.date,
                    endIsDateOnly: parsedEnd.isDateOnly,
                    calendar: calendar
                )
                event.startDate = bounds.start
                event.endDate = bounds.end
                event.isAllDay = true
            } else {
                event.startDate = startDate
                event.endDate = endDate
            }

            var targetCalendar = self.eventStore.defaultCalendarForNewEvents
            if case .string(let calendarName) = arguments["calendar"] {
                targetCalendar = try requireSingleCalendar(
                    self.eventStore.editableCalendars(named: calendarName, for: .event),
                    named: calendarName, kind: "Calendar", listTool: "calendars_list"
                )
            }
            event.calendar = targetCalendar

            if case .string(let location) = arguments["location"] { event.location = location }
            if case .string(let notes) = arguments["notes"] { event.notes = notes }
            if case .string(let urlString) = arguments["url"], let url = URL(string: urlString) { event.url = url }
            if case .string(let availability) = arguments["availability"] {
                event.availability = EKEventAvailability(availability)
            }

            if case .array(let alarmConfigs) = arguments["alarms"] {
                var alarms: [EKAlarm] = []
                for alarmConfig in alarmConfigs { /* lines 462-532: relative / absolute / proximity */ }
                event.alarms = alarms
            }

            try self.eventStore.save(event, span: .thisEvent)

            return Event.identified(event)
        }
```

The `alarms` property of the `events_create` input schema is one large
`.array(description:items: .anyOf([...]))` literal at `Calendar.swift:294-371`.

### `events_delete` occurrence lookup today (`Calendar.swift:573-631`)

```swift
        ) { arguments in
            try await self.activate()

            guard case .string(let identifier) = arguments["identifier"], !identifier.isEmpty else {
                throw ToolInputError("Event identifier is required")
            }
            let span = try calendarEventsDeleteSpan(from: arguments)

            // Every occurrence of a recurring event shares one identifier, and
            // `event(withIdentifier:)` always resolves it to the first one. With
            // a start date, refetch that exact occurrence so `thisEvent` removes
            // the right one and `futureEvents` starts from it, not from the
            // whole series.
            guard let anyOccurrence = self.eventStore.event(withIdentifier: identifier) else {
                throw ToolInputError("No event found with that identifier")
            }

            let event: EKEvent
            if case .string(let startString) = arguments["start"] {
                guard
                    let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: startString
                    )
                else {
                    throw ToolInputError("Invalid start date format. Expected ISO 8601 format.")
                }
                let startDate = Calendar.current.normalizedStartDate(
                    from: parsedStart.date,
                    isDateOnly: parsedStart.isDateOnly
                )
                let predicate = self.eventStore.predicateForEvents(
                    withStart: startDate,
                    end: startDate.addingTimeInterval(1),
                    calendars: nil
                )
                guard
                    let occurrence = self.eventStore.events(matching: predicate).first(where: {
                        $0.eventIdentifier == identifier
                            && abs($0.startDate.timeIntervalSince(startDate)) < 1
                    })
                else {
                    throw ToolInputError("No occurrence of that event starts at the given start date")
                }
                event = occurrence
            } else if anyOccurrence.hasRecurrenceRules {
                throw ToolInputError(
                    "That event is recurring. Pass the start date of the occurrence to delete."
                )
            } else {
                event = anyOccurrence
            }

            try self.eventStore.remove(event, span: span, commit: true)

            return Value.object([
                "deleted": .bool(true),
                "identifier": .string(identifier),
            ])
        }
```

`events_update` needs the same lookup. In `events_delete` the occurrence
selector is the argument `start`; in `events_update`, `start` means the NEW
start time, so the selector there is named `occurrenceStart`.

The span parser (`Calendar.swift:87-98`):

```swift
/// An unknown span is rejected rather than read as `thisEvent`, so a typo
/// cannot quietly delete less (or more) than the caller meant.
func calendarEventsDeleteSpan(from arguments: [String: Value]) throws -> EKSpan {
    switch arguments["span"] {
    case nil, .string("thisEvent"):
        return .thisEvent
    case .string("futureEvents"):
        return .futureEvents
    default:
        throw ToolInputError("Invalid span. Expected \"thisEvent\" or \"futureEvents\".")
    }
}
```

### Removing a reminder in EventKit

`reminders_delete` is modelled on `events_delete` above: argument
`identifier`, a `ToolInputError` when nothing matches, and a
`{"deleted": true, "identifier": ...}` result. It differs in one way that
EventKit forces. The SDK header (`EventKit/EKEventStore.h`) declares

```objc
- (BOOL)removeReminder:(EKReminder *)reminder commit:(BOOL)commit error:(NSError **)error;
```

which Swift imports as `try store.remove(reminder, commit: true)`. There is
no `span` parameter, unlike `remove(_:span:commit:)` for events. A repeating
reminder is one `EKReminder` carrying `recurrenceRules`; EventKit does not
expand it into occurrences. Removing it therefore removes the reminder and
its repeat rule together, and no future repeat appears. There is no API to
delete a single occurrence, so `reminders_delete` has no `span` and no
`start` argument. The header also says that passing a reminder from another
`EKEventStore` raises an exception; the handler looks the reminder up in
`self.eventStore` and removes it from the same store.

`events_delete` has no handler-level test (only its span parser is tested,
`testEventsDeleteSpanRejectsUnknownValues`), because the handler needs
calendar access and a real store. The same holds for `reminders_delete`; see
"Test plan".

### Place deletion today

`LocationHistoryStore.swift:481-494`:

```swift
    /// Removes a named place. Matched by name, case-insensitively, because
    /// that is the handle the user has.
    func deletePlace(named name: String) throws {
        let db = try connection()
        guard let match = try places().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { throw LocationHistoryError.unknownPlace(name) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM places WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw unavailable(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, match.id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw unavailable(db) }
    }
```

Only caller, `LocationWindow.swift:405-412`:

```swift
    func deletePlace(_ place: NamedPlace) async {
        do {
            try await store.deletePlace(named: place.name)
            await reload()
        } catch {
            loadError = error.localizedDescription
        }
    }
```

`location_place_set` rejects an empty name with
`throw LocationHistoryError.unknownPlace("")` (`Location.swift:725-727`).
`LocationHistoryError` is `ClientFacingError`
(`LocationHistoryStore.swift:128-144`); `.invalidRequest(String)` passes its
text through verbatim.

### Conventions that apply

- Swift 6 strict concurrency, warnings are errors, deployment target macOS
  15.1. Local Xcode is 27 beta, CI is Xcode 26.0. Xcode 26 times out
  type-checking very large literals: when you move the alarms schema into a
  constant (Step 3), give the constant an explicit type annotation.
- Tools are declared inside each service's `var tools: [Tool]` result builder.
  The `Tool` initialiser is in `App/Models/Tool.swift`:
  `Tool(name:description:inputSchema:annotations:) { arguments in ... }`,
  where `arguments` is `[String: Value]` and the closure returns an
  `Encodable` or a `Value`.
- `ToolSchemaHygieneTests` (`CallToolDispatchTests.swift:89-124`) fails any
  tool whose property names leave `[a-zA-Z0-9_.-]`, and any tool that
  documents both `start` and `startDate`. The names chosen below pass.
- Annotation rule (written by plan 039, pinned by `ToolAnnotationTests`,
  which 039 appends to `iMCPTests/CallToolDispatchTests.swift`): a tool that
  can replace or remove existing user data is `destroy` — `readOnlyHint:
  false`, `destructiveHint: true`. A tool that only touches data on this Mac
  is `local` — `openWorldHint: false`. `idempotentHint` is omitted on every
  tool; that test asserts it is nil. All four new tools are `destroy local`,
  the same row `events_delete` has after plan 039.
  Do not write `idempotentHint` on them, even though a repeated update or
  delete is in fact harmless: 039's rule is the project's rule.
- Partial-update contract (same as plan 041's for contacts): a supplied field
  overwrites; an unsupplied field is not touched. For list-valued fields
  (`alarms`), supplying the field replaces the whole list and an empty array
  clears it; omitting it leaves the alarms alone.
- Commit style: conventional commits, for example
  `feat(messages): add conversations, attachments, and chatId to messages_fetch`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 (`-quiet` may print nothing) |
| App tests | `Scripts/test.sh --app-only` | all pass |
| One test class | `Scripts/test.sh --only iMCPTests/<TestClass>` | all pass (`--only` passes `-only-testing:<SPEC>` and implies app-only) |
| Both suites | `Scripts/test.sh` | all pass |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

Never run `xcodebuild test -scheme iMCP` directly: the always-on watchdog
relaunches the installed app and breaks the test host. Never
`launchctl bootout` the always-on agent. `Scripts/test.sh` handles both.

## Scope

**In scope** (the only files you should modify):

- `App/Services/Reminders.swift`
- `App/Services/Calendar.swift`
- `App/Services/Location.swift`
- `App/Services/Location/LocationHistoryStore.swift`
- `iMCPTests/CallToolDispatchTests.swift`
- `iMCPTests/LocationRenewalAndTimelineTests.swift`
- `README.md`
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):

- Any way to delete more than one reminder per call, or to pick the reminder
  by anything but its identifier: no array of identifiers, no delete-by-title,
  no delete-by-list, no "delete all completed". The owner asked for a tool an
  agent calls once per reminder, so every deletion is named in the
  transcript.
- A `span` or occurrence argument on `reminders_delete`. EventKit has none
  for reminders (see "Removing a reminder in EventKit").
- Other bulk operations, event attendees, recurrence-rule editing, clearing
  a reminder's due date.
- Per-tool enable switches, a `contacts_list` tool, a Notes create tool, an
  activity log, a confirmation-prompt system. The owner explicitly declined
  all five.
- Any new validation of fields the create handlers already accept. Plan 038
  owns argument validation; this plan moves that code and inherits whatever
  038 left there.
- `location_place_set` validation and duplicate-name handling — plan 040.
- `App/Views/LocationWindow.swift` — its call to `deletePlace(named:)` keeps
  compiling unchanged (see Step 5).
- `App/Extensions/EventKit+Extensions.swift`, `App/Models/FetchPolicy.swift`,
  `App/Controllers/ToolErrorResponse.swift` — used as they are.
- `iMCP.xcodeproj/project.pbxproj` — no new files are created, so no project
  edit is needed. If you find yourself wanting a new file, that is a STOP
  condition.

## Git workflow

- Start from an up-to-date `main` that contains plans 038, 039 and 041.
- Branch: `advisor/054-write-verbs`
- One commit per step that changes code, conventional commits, for example
  `refactor(reminders): share field parsing between create and update`,
  `feat(reminders): add reminders_update`,
  `feat(reminders): add reminders_delete`,
  `feat(calendar): add events_update`,
  `feat(location): add location_place_delete`.
- Do NOT push or open a PR unless the operator instructed it. `origin`
  (`cyberpapiii/iMCP`) is the only writable remote; `upstream` (`mattt/iMCP`)
  must never receive pushes or PRs.

## Steps

### Step 0: Confirm the dependencies landed

Run each check. All three must hold.

1. `grep -nE '^\| *0?(38|39|41) ' plans/README.md` → three rows, each with
   status `DONE`.
2. `grep -c 'final class ToolAnnotationTests' iMCPTests/CallToolDispatchTests.swift`
   → `1`. If `0`, plan 039 has not landed.
3. `grep -n 'TimeInterval(-minutes \* 60)' App/Services/Reminders.swift App/Services/Calendar.swift`
   → no matches (plan 038 replaced the overflowing expression). If it still
   matches, 038 has not landed.

If any check fails, STOP.

Then read, in the two dependency plans, the two things this plan reuses:

- In `plans/039-correct-tool-annotations.md`: the written annotation rule.
  Confirm it still says `idempotentHint` is omitted everywhere and that
  `ToolAnnotationTests.table` has the row format described above.
- In `plans/038-validate-tool-arguments.md`: the name of the shared
  integer-argument helper and how the reminder `due` parser now throws. You
  will not call these directly; you need to recognise them in the code you
  move.

**Verify**: `git status --short` → empty (clean tree on the new branch).

### Step 1: Share reminder field parsing between create and update

File: `App/Services/Reminders.swift`.

Add one free function next to `requireSingleCalendar` (bottom of the file).
Its body is the field-setting code of the `reminders_create` handler, **moved
verbatim** from the live file (everything from the `list` lookup down to and
including the `alarms` block), with `self.eventStore` replaced by the `store`
parameter and with two small differences shown here:

```swift
/// Sets only the fields the caller supplied, so `reminders_create` and
/// `reminders_update` share one definition of each field. A field that is
/// absent from `arguments` is left exactly as it was.
func applyReminderFields(
    _ arguments: [String: Value],
    to reminder: EKReminder,
    in store: EKEventStore
) throws {
    if case .string(let title) = arguments["title"] {
        reminder.title = title
    }

    if case .string(let listName) = arguments["list"] {
        reminder.calendar = try requireSingleCalendar(
            store.editableCalendars(named: listName, for: .reminder),
            named: listName,
            kind: "Reminder list",
            listTool: "reminders_lists"
        )
    }

    // ... `due`, `notes`, `priority`, `alarms` blocks moved verbatim ...

    if let completed = arguments["completed"] {
        guard case .bool(let isCompleted) = completed else {
            throw ToolInputError("completed must be true or false")
        }
        reminder.isCompleted = isCompleted
    }
}
```

The two differences from the create handler are deliberate: the `list` block
assigns only when `list` is supplied (the default list is create's business,
below), and the `completed` block is new.

Then reduce the `reminders_create` handler to:

```swift
        ) { arguments in
            try await self.activate()

            guard case .string = arguments["title"] else {
                throw ToolInputError("Reminder title is required")
            }
            let reminder = EKReminder(eventStore: self.eventStore)
            reminder.calendar = self.eventStore.defaultCalendarForNewReminders()
            try applyReminderFields(arguments, to: reminder, in: self.eventStore)

            try self.eventStore.save(reminder, commit: true)

            return PlanAction(reminder)
        }
```

Do not change the `reminders_create` schema, description or annotations.

**Verify**:
- Build command → exit 0.
- `grep -c 'arguments\["due"\]' App/Services/Reminders.swift` → `1` (the
  `due` parsing exists once, inside `applyReminderFields`).
- `Scripts/test.sh --app-only` → all pass (no behaviour change yet).

Commit: `refactor(reminders): share field parsing between create and update`.

### Step 2: Add `reminders_update`

File: `App/Services/Reminders.swift`.

First add the lookup as a free function next to `applyReminderFields`. Step
2b's `reminders_delete` uses the same function; it is the only place in the
file that resolves an identifier.

```swift
/// The one reminder the caller named. An identifier that matches nothing is
/// the caller's to fix, so this throws instead of returning nil.
func requireReminder(_ arguments: [String: Value], in store: EKEventStore) throws -> EKReminder {
    guard case .string(let identifier) = arguments["identifier"], !identifier.isEmpty else {
        throw ToolInputError("Reminder identifier is required")
    }
    guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
        throw ToolInputError(
            "No reminder found with that identifier. Call reminders_fetch for current identifiers."
        )
    }
    return reminder
}
```

Then add this tool to the `tools` builder directly after `reminders_create`.

```swift
        Tool(
            name: "reminders_update",
            description:
                "Edit or complete a reminder by identifier and return the saved reminder. Only the fields you pass change; everything else is left as it is. Pass completed: true to tick it off.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description:
                            "Identifier of the reminder: the @id value from a recent reminders_fetch"
                    ),
                    "title": .string(),
                    "completed": .boolean(
                        description: "true marks the reminder done; false reopens it"
                    ),
                    "due": .string(
                        description:
                            "New due date/time. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "list": .string(
                        description: "Move the reminder to this list, matched case-insensitively"
                    ),
                    "notes": .string(),
                    "priority": .string(
                        enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description:
                            "Minutes before the due date to fire each alarm. Replaces every existing alarm; an empty array removes them all.",
                        items: .integer()
                    ),
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Reminder",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            let reminder = try requireReminder(arguments, in: self.eventStore)
            try applyReminderFields(arguments, to: reminder, in: self.eventStore)

            try self.eventStore.save(reminder, commit: true)

            return PlanAction(reminder)
        }
```

Notes for the executor:

- If plan 038 put a `maximum`/`minimum` on `reminders_create`'s `alarms`
  items, copy the same bounds onto the `items: .integer()` here so both tools
  advertise the same range.
- No `idempotentHint`: see the annotation rule in "Conventions that apply".
- `priority` has no `default:` here on purpose: on update, omitted means
  "unchanged", not "none".

In the same commit, add the tool's row to `ToolAnnotationTests.table` in
`iMCPTests/CallToolDispatchTests.swift`, after the `reminders_lists` row and
with the same indentation as its neighbours:

```
        reminders_update destroy local
```

Without the row, `testEveryToolAnnotationMatchesTheTable` fails with "Add,
rename, or remove the tool's row in the table".

**Verify**:
- Build command → exit 0.
- `grep -c 'name: "reminders_update"' App/Services/Reminders.swift` → `1`.
- `grep -c 'calendarItem(withIdentifier' App/Services/Reminders.swift` → `1`
  (inside `requireReminder`, nowhere else).
- `Scripts/test.sh --only iMCPTests/ToolSchemaHygieneTests --only iMCPTests/ToolAnnotationTests`
  → all pass.

Commit: `feat(reminders): add reminders_update`.

### Step 2b: Add `reminders_delete`

File: `App/Services/Reminders.swift`. Add this tool to the `tools` builder
directly after `reminders_update`, as the last tool in the builder. It
mirrors `events_delete` (`Calendar.swift:542-631`, excerpt in "Current
state") minus `start` and `span`, which EventKit does not have for reminders.

```swift
        Tool(
            name: "reminders_delete",
            description:
                "Delete one reminder by identifier and report its identifier and title. This removes the reminder for good; iMCP cannot undo it. A repeating reminder is deleted whole, with every future repeat: a single occurrence cannot be deleted. To tick a reminder off and keep it, use reminders_update with completed: true.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description:
                            "Identifier of the reminder to delete: the @id value from a recent reminders_fetch"
                    )
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Reminder",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            let reminder = try requireReminder(arguments, in: self.eventStore)
            // Read before removing: a removed item is no longer tied to the store.
            let deleted = Value.object([
                "deleted": .bool(true),
                "identifier": .string(reminder.calendarItemIdentifier),
                "title": .string(reminder.title ?? ""),
            ])

            try self.eventStore.remove(reminder, commit: true)

            return deleted
        }
```

Notes for the executor:

- One reminder per call, selected only by `identifier`. Do not add a second
  selector, an array form, or a `span`. See "Out of scope".
- An unknown, stale or empty identifier throws the `ToolInputError` from
  `requireReminder`. The handler never returns `deleted: false`; unlike
  `location_place_delete`, a miss here is an error, as it is in
  `events_delete`.
- The result is `events_delete`'s shape plus `title`, so the client's
  transcript names what was removed.
- No `idempotentHint`: see the annotation rule in "Conventions that apply".

In the same commit, add the tool's row to `ToolAnnotationTests.table` in
`iMCPTests/CallToolDispatchTests.swift`, after the `reminders_create` row
(the table is sorted by name):

```
        reminders_delete destroy local
```

**Verify**:
- Build command → exit 0.
- `grep -c 'name: "reminders_delete"' App/Services/Reminders.swift` → `1`.
- `grep -c 'requireReminder(arguments' App/Services/Reminders.swift` → `2`
  (one call in each of `reminders_update` and `reminders_delete`).
- `grep -c 'calendarItem(withIdentifier' App/Services/Reminders.swift` → `1`.
- `grep -c 'eventStore.remove(' App/Services/Reminders.swift` → `1`.
- `Scripts/test.sh --only iMCPTests/ToolSchemaHygieneTests --only iMCPTests/ToolAnnotationTests`
  → all pass.

Commit: `feat(reminders): add reminders_delete`.

### Step 3: Share event field parsing between create and update

File: `App/Services/Calendar.swift`. Four moves, no behaviour change except
the two error messages called out below.

**3a. Rename the span parser**, because update will use it too. Rename
`calendarEventsDeleteSpan` to `calendarEventSpan` in `Calendar.swift` (the
definition at line 89 and the call in `events_delete`) and in
`iMCPTests/CallToolDispatchTests.swift` (five calls at lines 128-132; leave
the test method name alone). Replace its doc comment with:

```swift
/// An unknown span is rejected rather than read as `thisEvent`, so a typo
/// cannot quietly change or delete less (or more) than the caller meant.
```

**3b. Move the alarms schema into a constant.** Cut the whole value of the
`"alarms":` key in the `events_create` schema (the `.array(description:items:
.anyOf([...]))` expression, lines 294-371 at `8165d29`) and paste it as a
file-level constant above `final class CalendarService`:

```swift
private let eventAlarmsSchema: JSONSchema = .array(
    // ... moved verbatim ...
)
```

In `events_create`, the entry becomes `"alarms": eventAlarmsSchema,`. Add
`import JSONSchema` at the top of the file if the build asks for it
(`App/Models/Tool.swift` imports it the same way). The explicit `: JSONSchema`
annotation is required; it keeps Xcode 26's type checker from timing out.

**3c. Extract the date logic** as a free function near `allDayEventBounds`.
This replaces the hand-rolled `guard case .string(let startDateStr) ...`
parse with the existing throwing parser in `FetchPolicy`:

```swift
/// The start and end an event should take, or nil when the caller named
/// neither bound and the event already has both.
///
/// Create passes `current: nil`, which makes both bounds required. Update
/// passes the event's own bounds: a lone `start` moves the event and keeps
/// its length, a lone `end` changes only its length.
func eventDateRange(
    from arguments: [String: Value],
    current: (start: Date, end: Date)?,
    isAllDay: Bool,
    calendar: Calendar = .current
) throws -> (start: Date, end: Date)? {
    let parsedStart = try FetchPolicy.parseRawDate(
        try FetchPolicy.dateString(from: arguments, primary: "start")
    )
    let parsedEnd = try FetchPolicy.parseRawDate(
        try FetchPolicy.dateString(from: arguments, primary: "end")
    )
    if parsedStart == nil, parsedEnd == nil, current != nil { return nil }

    guard let rawStart = parsedStart?.date ?? current?.start else {
        throw ToolInputError("Event start and end are required")
    }
    let start = calendar.normalizedStartDate(from: rawStart, isDateOnly: parsedStart?.isDateOnly ?? false)

    // A lone new start keeps the event's length.
    let rawEnd: Date
    if let parsedEnd {
        rawEnd = parsedEnd.date
    } else if let current {
        rawEnd = start.addingTimeInterval(current.end.timeIntervalSince(current.start))
    } else {
        throw ToolInputError("Event start and end are required")
    }
    let endIsDateOnly = parsedEnd?.isDateOnly ?? false

    // An all-day event has to span whole local days, so its bounds come from
    // the raw end date rather than the normalized one.
    let range =
        isAllDay
        ? allDayEventBounds(startDate: start, endDate: rawEnd, endIsDateOnly: endIsDateOnly, calendar: calendar)
        : (start: start, end: calendar.normalizedEndDate(from: rawEnd, isDateOnly: endIsDateOnly))

    guard range.start <= range.end else {
        throw ToolInputError("Event start must not be after its end")
    }
    return range
}
```

Two message changes follow from this and are intended: an unparseable `start`
or `end` on `events_create` now reports `FetchPolicy.Error.invalidDate`
("Date argument is unparseable", already client-facing) instead of "Invalid
start or end date format. Expected ISO 8601 format."; and an event whose start
is after its end is now rejected instead of being handed to EventKit.

**3d. Extract the field setter** as a free function below `eventDateRange`.
Everything except the first two blocks is **moved verbatim** from the
`events_create` handler (`calendar`, `location`, `notes`, `url`,
`availability`, and the whole `alarms` loop), with `self.eventStore` replaced
by `store`:

```swift
/// Sets only the fields the caller supplied, so `events_create` and
/// `events_update` share one definition of each field. A field that is
/// absent from `arguments` is left exactly as it was.
func applyEventFields(
    _ arguments: [String: Value],
    to event: EKEvent,
    in store: EKEventStore
) throws {
    if case .string(let title) = arguments["title"] {
        event.title = title
    }

    if case .bool(let isAllDay) = arguments["isAllDay"] {
        event.isAllDay = isAllDay
    }
    // A new EKEvent has no dates yet; an existing one always has both.
    let current: (start: Date, end: Date)? =
        if let start = event.startDate, let end = event.endDate { (start, end) } else { nil }
    if let range = try eventDateRange(from: arguments, current: current, isAllDay: event.isAllDay) {
        event.startDate = range.start
        event.endDate = range.end
    }

    if case .string(let calendarName) = arguments["calendar"] {
        event.calendar = try requireSingleCalendar(
            store.editableCalendars(named: calendarName, for: .event),
            named: calendarName,
            kind: "Calendar",
            listTool: "calendars_list"
        )
    }

    // ... `location`, `notes`, `url`, `availability`, `alarms` blocks moved verbatim ...
}
```

`EKEvent.startDate` and `endDate` are implicitly unwrapped optionals; the
`if let` above is what reads a brand-new event's missing dates as nil. If the
compiler rejects `if let` on them, bind through an explicit optional
(`let start: Date? = event.startDate`) rather than force-reading.

Then reduce the `events_create` handler to:

```swift
        ) { arguments in
            try await self.activate()

            guard case .string = arguments["title"] else {
                throw ToolInputError("Event title is required")
            }
            let event = EKEvent(eventStore: self.eventStore)
            event.calendar = self.eventStore.defaultCalendarForNewEvents
            try applyEventFields(arguments, to: event, in: self.eventStore)

            try self.eventStore.save(event, span: .thisEvent)

            return Event.identified(event)
        }
```

**3e. Extract the occurrence lookup** from `events_delete` into a private
method on `CalendarService` (put it after `activate()`). The body is the
block from `guard let anyOccurrence` through the closing brace of the
`if/else if/else` (lines 586-623 at `8165d29`), **moved verbatim**, with
three edits: it reads the selector from a parameter instead of
`arguments["start"]`, the two messages that name the argument use
`startKey`, and it returns the event.

```swift
    /// Every occurrence of a recurring event shares one identifier, and
    /// `event(withIdentifier:)` always resolves it to the first one. With a
    /// start date, refetch that exact occurrence so `thisEvent` touches the
    /// right one and `futureEvents` starts from it, not from the whole series.
    /// `startKey` is the caller's name for the selector, used in messages.
    private func event(
        identifier: String,
        occurrenceStart: Value?,
        startKey: String
    ) throws -> EKEvent {
        guard let anyOccurrence = eventStore.event(withIdentifier: identifier) else {
            throw ToolInputError("No event found with that identifier")
        }
        if case .string(let startString) = occurrenceStart {
            // ... moved verbatim; the parse-failure message becomes
            // "Invalid \(startKey) date format. Expected ISO 8601 format."
            // and the not-found message becomes
            // "No occurrence of that event starts at the given \(startKey)"
            return occurrence
        }
        if anyOccurrence.hasRecurrenceRules {
            throw ToolInputError(
                "That event is recurring. Pass \(startKey) with the start date of the occurrence."
            )
        }
        return anyOccurrence
    }
```

`events_delete` then reads:

```swift
            let span = try calendarEventSpan(from: arguments)
            let event = try self.event(
                identifier: identifier,
                occurrenceStart: arguments["start"],
                startKey: "start"
            )

            try self.eventStore.remove(event, span: span, commit: true)
```

Keep the explanatory comment only once, on the new method; delete the copy
inside `events_delete`.

**Verify**:
- Build command → exit 0.
- `grep -c 'calendarEventsDeleteSpan' App/Services/Calendar.swift iMCPTests/CallToolDispatchTests.swift`
  → `0` for both files.
- `grep -c 'predicateForEvents' App/Services/Calendar.swift` → `2` (one in
  `events_fetch`, one in the new `event(identifier:...)` method).
- `grep -c 'case "proximity":' App/Services/Calendar.swift` → `1`.
- `Scripts/test.sh --app-only` → all pass.

Commit: `refactor(calendar): share field parsing and occurrence lookup`.

### Step 4: Add `events_update`

File: `App/Services/Calendar.swift`. Add this tool between `events_create` and
`events_delete`.

```swift
        Tool(
            name: "events_update",
            description:
                "Edit a calendar event by identifier and return the saved event. Only the fields you pass change; everything else, including attendees, is left as it is. Pass start alone to move the event and keep its length. For a recurring event, pass occurrenceStart to pick the occurrence.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description: "Identifier of the event: the @id value events_fetch returns"
                    ),
                    "occurrenceStart": .string(
                        description:
                            "Current start date/time of the occurrence to edit. Required for recurring events, since every occurrence shares one identifier.",
                        format: .dateTime
                    ),
                    "span": .string(
                        description:
                            "For recurring events: change only this occurrence, or this and all future ones",
                        default: .string("thisEvent"),
                        enum: ["thisEvent", "futureEvents"]
                    ),
                    "title": .string(),
                    "start": .string(
                        description:
                            "New start date/time. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "New end date/time. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "calendar": .string(
                        description: "Move the event to this calendar, matched case-insensitively"
                    ),
                    "location": .string(),
                    "notes": .string(),
                    "url": .string(
                        format: .uri
                    ),
                    "isAllDay": .boolean(),
                    "availability": .string(
                        description: "How the event marks the user's time to other people",
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": eventAlarmsSchema,
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Event",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard case .string(let identifier) = arguments["identifier"], !identifier.isEmpty else {
                throw ToolInputError("Event identifier is required")
            }
            let span = try calendarEventSpan(from: arguments)
            let event = try self.event(
                identifier: identifier,
                occurrenceStart: arguments["occurrenceStart"],
                startKey: "occurrenceStart"
            )
            try applyEventFields(arguments, to: event, in: self.eventStore)

            try self.eventStore.save(event, span: span, commit: true)

            return Event.identified(event)
        }
```

Notes:

- The shared `eventAlarmsSchema` description says "Alarms to attach." On
  update, supplying `alarms` replaces the whole list. Say so once, in the
  constant's description, so both tools read correctly: change it to
  "Alarms for the event. On update this replaces every existing alarm. Each
  one is relative to the start, at an absolute time, or tied to a place."
- `isAllDay` and `availability` carry no `default:` here: on update, omitted
  means "unchanged".

In the same commit, add the row `events_update destroy local` to
`ToolAnnotationTests.table`, after the `events_fetch` row.

**Verify**:
- Build command → exit 0.
- `grep -c 'name: "events_update"' App/Services/Calendar.swift` → `1`.
- `grep -c 'eventAlarmsSchema' App/Services/Calendar.swift` → `3` (the
  definition and two uses).
- `Scripts/test.sh --only iMCPTests/ToolSchemaHygieneTests --only iMCPTests/ToolAnnotationTests`
  → all pass.

Commit: `feat(calendar): add events_update`.

### Step 5: Add `location_place_delete`

**5a. Store** — `App/Services/Location/LocationHistoryStore.swift`. Make
`deletePlace(named:)` report whether it removed anything instead of throwing
for an unknown name. This deletes a throw path, and a repeated delete then
answers `deleted: false` instead of failing.
Only the signature, the doc comment, the `guard ... else` line and the last
line change:

```swift
    /// Removes a named place and reports whether one was there. Matched by
    /// name, case-insensitively, because that is the handle the user has.
    @discardableResult
    func deletePlace(named name: String) throws -> Bool {
        let db = try connection()
        guard let match = try places().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return false }
        // ... prepare, bind, step: unchanged ...
        guard sqlite3_step(statement) == SQLITE_DONE else { throw unavailable(db) }
        return true
    }
```

`App/Views/LocationWindow.swift:407` (`try await store.deletePlace(named:
place.name)`) keeps compiling because of `@discardableResult`. Do not edit
that file.

**5b. Tool** — `App/Services/Location.swift`. Add this tool directly after
`location_place_set`, as the last tool in the builder (before the closing
brace at line 758 at `8165d29`):

```swift
        Tool(
            name: "location_place_delete",
            description:
                "Delete a named place by name. Recorded positions are kept; stays there simply stop carrying the name. Reports whether a place was removed.",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description:
                            "The place's name as location_places reports it, matched case-insensitively."
                    )
                ],
                required: ["name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete a Place",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
                throw LocationHistoryError.invalidRequest("Place name is required")
            }
            return Value.object([
                "deleted": .bool(try await self.historyStore.deletePlace(named: name)),
                "name": .string(name),
            ])
        }
```

The result shape mirrors `events_delete`
(`{"deleted": true, "identifier": ...}`). Like `location_place_set`, this
tool needs no iCloud session and no people-access check: named places are
local data.

**5c. Table row** — add `location_place_delete destroy local` to
`ToolAnnotationTests.table`, before the `location_place_set` row.

**Verify**:
- Build command → exit 0.
- `grep -c 'name: "location_place_delete"' App/Services/Location.swift` → `1`.
- `Scripts/test.sh --app-only` → all pass (this includes
  `LocationTimelineItemsTests`, which exercises the window's delete through
  the changed store method, and `ToolAnnotationTests`).

Commit: `feat(location): add location_place_delete`.

### Step 6: Tests

See "Test plan" for the cases A and B. Add them. (The annotation-table rows
were already added in Steps 2, 2b, 4 and 5.)

**Verify**: `Scripts/test.sh --app-only` → all pass, including the new tests
and the annotation table test.

Commit: `test: cover the update and delete tools`.

### Step 7: README

File: `README.md`. Two rows of the capabilities table and one list.

- Calendar row (line 27 at `8165d29`): replace the cell text with
  "View and manage calendar events: create, update, and delete events with
  customizable settings like recurrence, alarms, and availability status."
- Reminders row (line 85): replace the cell text with
  "View, create, edit, complete, and delete reminders with customizable due
  dates, priorities, and alerts across different reminder lists."
- Location tools list (after the `location_places` bullet, line 503-505):
  add one bullet in the same style:
  "- `location_place_set` and `location_place_delete`: name a place, or
  remove a name. Deleting a place never deletes recorded positions."

Plan 053 (docs accuracy) may have reworded these lines. If so, keep 053's
wording and add only the missing verbs ("update", "edit", "complete",
"delete" for reminders) and the one bullet.

**Verify**:
- `grep -c 'location_place_delete' README.md` → `1`.
- `grep -c 'edit, complete, and delete reminders' README.md` → `1` (or, if
  053 reworded the row, `grep -i 'reminders' README.md | grep -ci 'complete.*delete'`
  → at least `1`).

Commit: `docs: list the update and delete tools`.

### Step 8: Format, lint, full run

**Verify**:
- `swift format -i -r .` then `swift format lint --strict --recursive .` → exit 0.
- `git status --short` → only in-scope files.
- Build command → exit 0.
- `Scripts/test.sh` → both suites pass.

Commit any formatting changes with the step they belong to (amend or a
`style:` commit). Then update the row for plan 054 in `plans/README.md`.

## Test plan

No new test files. All EventKit tests run on **unsaved** objects: an
`EKReminder` or `EKEvent` created against a fresh `EKEventStore()` and never
passed to `save`. Creating the store and the object does not request access,
does not prompt, and writes nothing. No test in this plan may call
`save`, `remove`, `requestFullAccess*`, `calendars(for:)`, reach
`calendarItem(withIdentifier:)`, or pass a `list` / `calendar` argument
(those are the only paths that read the store).
The model for "test the merge on a framework object, never the store" is
`ContactCardTests` in `iMCPTests/AppModelTests.swift` (around line 642), which
does the same with `CNMutableContact`.

**A. Append a new class `WriteVerbMergeTests` to
`iMCPTests/CallToolDispatchTests.swift`** (the file already imports EventKit).
Structure it like `ToolSchemaHygieneTests` in the same file. Cases:

Reminders (`applyReminderFields`):

1. `testReminderUpdateLeavesUnsuppliedFieldsAlone` — build a reminder with
   title "Buy milk", notes "2%", priority high (`Int(EKReminderPriority.high.rawValue)`);
   apply `["notes": .string("oat")]`; assert title and priority unchanged,
   notes "oat".
2. `testReminderCompletedTicksOffAndReopens` — apply `["completed": .bool(true)]`
   → `isCompleted` true; apply `["completed": .bool(false)]` → false.
3. `testReminderCompletedRejectsANonBoolean` — apply
   `["completed": .string("yes")]` → throws, and the error is a
   `ToolInputError`.
4. `testReminderEmptyAlarmsClearsAndOmittedAlarmsKeep` — give the reminder
   one `EKAlarm(relativeOffset: -600)`; apply `["title": .string("x")]` →
   one alarm still; apply `["alarms": .array([])]` → `alarms` is nil or empty
   (`XCTAssertTrue(reminder.alarms?.isEmpty ?? true)`).
5. `testReminderDueIsSetFromADateOnlyString` — apply
   `["due": .string("2026-12-31")]` → `dueDateComponents?.year == 2026`,
   `month == 12`, `day == 31`.

Event dates (`eventDateRange`, pure, no EventKit object). Use a fixed
gregorian UTC calendar exactly as `testAllDayEventBoundsKeepDateOnlyEndOnRequestedDay`
does (`iMCPTests/AppModelTests.swift:411-431`), and pass ISO strings with an
explicit `Z` so the local time zone cannot matter:

6. `testEventRangeIsNilWhenUpdateNamesNoBound` — `current` set, no `start`
   or `end` → returns nil.
7. `testEventRangeRequiresBothBoundsOnCreate` — `current: nil` with only
   `start` → throws `ToolInputError`; with neither → throws.
8. `testALoneStartMovesTheEventAndKeepsItsLength` — current 10:00-11:30,
   `start` 14:00 → returns 14:00-15:30.
9. `testALoneEndChangesOnlyTheLength` — current 10:00-11:30, `end` 12:00 →
   returns 10:00-12:00.
10. `testEventRangeRejectsAnEndBeforeTheStart` — current 10:00-11:30, `end`
    09:00 → throws `ToolInputError`.
11. `testEventRangeRejectsAnUnparseableDate` — `start` "tomorrow" → throws,
    and `sanitizedToolErrorMessage(for:)` of the error is
    "Date argument is unparseable".
12. `testAllDayRangeSpansWholeDays` — `isAllDay: true`, current nil, `start`
    "2026-07-02T14:00:00Z", `end` "2026-07-04T09:00:00Z" with the fixed
    calendar → start hour 0 on day 2, end 23:59:59 on day 4. (Do not use
    date-only strings here: they parse to midnight in the machine's own time
    zone, which makes the UTC day depend on where the test runs.)

Events (`applyEventFields`, unsaved `EKEvent`):

13. `testEventUpdateLeavesUnsuppliedFieldsAlone` — event with title
    "Standup", location "Room 4", start/end set, one relative alarm; apply
    `["location": .string("Room 9")]`; assert title, start, end unchanged,
    alarm count still 1, location "Room 9".
14. `testEventAlarmsAreReplacedWhenSupplied` — same event; apply
    `["alarms": .array([])]` → `alarms` nil or empty.

Reminder lookup (`requireReminder`). Numbered 17 because it was added after
the others; it belongs in this class, after test 5:

17. `testReminderLookupRequiresAnIdentifier` — against a fresh
    `EKEventStore()`, `requireReminder([:], in: store)`,
    `requireReminder(["identifier": .string("")], in: store)` and
    `requireReminder(["identifier": .int(1)], in: store)` each throw, and each
    error is a `ToolInputError`. All three fail the first guard, so the store
    is never read. This is the guard that keeps `reminders_delete` and
    `reminders_update` from acting without a named target.

Not covered by an automated test, on purpose: the unknown-identifier error
and the removal itself. Both need `calendarItem(withIdentifier:)` or
`remove` on a real store, which the rule above forbids (the test host is
the iMCP app and may hold real Reminders access). `events_delete`, the
exemplar, has the same gap. They are checked by hand before release; see
"What to scrutinise in review" in Maintenance notes.

**B. Add two tests to `LocationTimelineToolTests` in
`iMCPTests/LocationRenewalAndTimelineTests.swift`**, modelled on
`testAWholeNumberRadiusIsHonoured` (line 430), using the class's existing
`service()` and `object(_:)` helpers:

15. `testDeletingAPlaceRemovesItAndASecondCallReportsNothingToDelete` —
    create "Juniper's" through `location_place_set`; call
    `location_place_delete` with `"name": .string("ray's")` (different case)
    → `deleted == true`; `try await store.places()` is empty; call again →
    `deleted == false`, no throw.
16. `testDeletingAPlaceRequiresAName` — call with `[:]` → throws, and the
    error equals `LocationHistoryError.invalidRequest("Place name is required")`.

**C.** The four rows in `ToolAnnotationTests.table` (added in Steps 2, 2b, 4
and 5), which make the existing `testEveryToolAnnotationMatchesTheTable` pin
the new tools' hints.

**Verification**: `Scripts/test.sh --app-only` → all pass, including 17 new
tests (15 in `WriteVerbMergeTests`, 2 in `LocationTimelineToolTests`). Narrow runs while iterating:
`Scripts/test.sh --only iMCPTests/WriteVerbMergeTests` and
`Scripts/test.sh --only iMCPTests/LocationTimelineToolTests`.

## Done criteria

ALL must hold:

- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `Scripts/test.sh` exits 0; `WriteVerbMergeTests` (15 tests) and the two new `LocationTimelineToolTests` tests exist and pass
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `grep -c 'name: "reminders_update"' App/Services/Reminders.swift` → 1
- [ ] `grep -c 'name: "reminders_delete"' App/Services/Reminders.swift` → 1
- [ ] `grep -c 'calendarItem(withIdentifier' App/Services/Reminders.swift` → 1 (one lookup, shared by update and delete)
- [ ] `grep -c 'eventStore.remove(' App/Services/Reminders.swift` → 1
- [ ] `grep -c '"span"' App/Services/Reminders.swift` → 0 (no span on reminders)
- [ ] `grep -c 'name: "events_update"' App/Services/Calendar.swift` → 1
- [ ] `grep -c 'name: "location_place_delete"' App/Services/Location.swift` → 1
- [ ] `grep -c 'arguments\["due"\]' App/Services/Reminders.swift` → 1 (no copied parsing)
- [ ] `grep -c 'case "proximity":' App/Services/Calendar.swift` → 1 (alarm parsing exists once)
- [ ] `grep -rn 'calendarEventsDeleteSpan' App iMCPTests` returns no matches
- [ ] `grep -c 'idempotentHint' App/Services/*.swift | awk -F: '{s+=$2} END {print s}'` → `0` (plan 039's rule still holds)
- [ ] `grep -cE '^ +(events_update|location_place_delete|reminders_delete|reminders_update) destroy local$' iMCPTests/CallToolDispatchTests.swift` → `4`
- [ ] `grep -c 'name: "reminders_' App/Services/Reminders.swift` → 5 (was 3)
- [ ] The registered tool count is the pre-plan count plus 4 (52 → 56 if no other plan added or removed a tool); `testEveryToolAnnotationMatchesTheTable` passing proves each one has a row
- [ ] `git diff --name-only main...HEAD` lists only in-scope files; `App/Views/LocationWindow.swift` and `iMCP.xcodeproj/project.pbxproj` are not in it
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any Step 0 check fails: this plan must not run before 038, 039 and 041.
- The create handlers no longer have the shape in "Current state" in a way
  the dependency plans do not explain — for example the field-setting code
  has already been extracted, or lives in another file.
- A test that only constructs `EKReminder(eventStore:)` or
  `EKEvent(eventStore:)` on a fresh `EKEventStore()` crashes, hangs, or brings
  up a permission prompt in the test host. Do not work around it by requesting
  access or by introducing a protocol or wrapper type around EventKit. Report
  it; the fallback the advisor would choose is to keep tests 6-12 and 15-16
  (which need no EventKit object) and drop 1-5 and 13-14. Test 17 creates
  only the store: keep it unless a bare `EKEventStore()` is what failed.
- Plan 037 (isolate tests from real state) added a rule or a guard that
  forbids creating `EKEventStore` in tests. Check with
  `grep -n 'EKEventStore' plans/037-*.md iMCPTests/*.swift`. If it does, same
  fallback plus dropping test 17, same report.
- `self.eventStore.remove(reminder, commit: true)` does not compile, or the
  compiler asks for a `span`. The plan's reading of EventKit is then wrong;
  do not guess at a span value.
- You find yourself giving `reminders_delete` a second selector (title,
  list, filter, an array of identifiers), a `span`, or a result that reports
  success without having removed a reminder. One identifier per call and an
  error on a miss are the owner's constraints, not details.
- `ToolSchemaHygieneTests` fails on one of the new tools.
- `ToolAnnotationTests` is missing, or its table no longer has the
  three-word row format, or plan 039's rule now allows `idempotentHint`.
- You find you need to edit `App/Views/LocationWindow.swift`, the Xcode
  project file, or any file not in scope.
- A verification fails twice after a reasonable fix attempt.
- Anything asks for a System Settings privacy grant, an Apple ID password,
  or a 2FA code. Those are HUMAN STEPs; hand off.

## Maintenance notes

- **Net size**: about +280 lines (four tool schemas and handlers plus the
  shared reminder lookup roughly +170, tests roughly +140, offset by about -30 from the hand-rolled date
  guard, the duplicated comment, and the alarm/occurrence code now existing
  once). The additions are the feature; nothing is duplicated to get it.
- **What to scrutinise in review**: that the moved blocks in
  `applyReminderFields` and `applyEventFields` are byte-for-byte the
  post-038 code (a diff with `--color-moved` shows this); that
  `events_create` on a brand-new event still requires both `start` and `end`;
  and that `events_update` with `span: futureEvents` plus `occurrenceStart`
  was tried by a human on a throwaway recurring event before release. That
  last check needs a real calendar and is not automatable here. The same
  goes for `reminders_delete`: before release a human should create three
  throwaway reminders and confirm that deleting a plain one returns
  `{"deleted": true, "identifier": ..., "title": ...}` and removes it from
  the Reminders app, that deleting a repeating one removes the whole series,
  and that calling again with the now-stale identifier returns "No reminder
  found with that identifier..." rather than success. The third reminder is
  for the subtask check below.
- **Not installed by this plan**: the executor does not run
  `Scripts/install-local.sh run`. The operator does that when they want the
  new tools in the installed app; MCP clients then need to reconnect to see
  the four new tools.
- **Reminder identifiers**: `@id` is `calendarItemIdentifier`, which Apple
  says can change after a full account sync. The tool tells callers to use a
  recent `reminders_fetch`. If stale identifiers turn out to be common in
  practice, the fix is a title-plus-list fallback lookup, not a different
  identifier (`calendarItemExternalIdentifier` is not unique for recurring
  items).
- **Recurring reminders**: setting `isCompleted` through EventKit completes
  the reminder as stored. Whether a repeating reminder then rolls forward to
  its next occurrence the way the Reminders app does was not verified in this
  plan. Check once by hand; if it does not, say so in the tool description
  rather than adding recurrence logic.
- **Deleting a repeating reminder**: `EKEventStore.remove(_:commit:)` for a
  reminder takes no span (confirmed in the SDK header), and EventKit holds a
  repeating reminder as one item with a recurrence rule. So
  `reminders_delete` removes the whole series and cannot remove one
  occurrence; the tool description says so. Two things were reasoned, not
  run: that completed copies the Reminders app already split off for past
  occurrences are separate items and stay, and what happens to subtasks
  (EventKit does not expose them; the Reminders app deletes them with their
  parent). Check both by hand with the throwaway reminders above, and put
  whichever turns out to surprise into the tool description.
- **Deletion is not recoverable through iMCP**: there is no undo tool and
  this plan adds no confirmation step (the owner declined a
  confirmation-prompt system). The safeguards are the `destroy` annotation,
  which lets a client ask before calling, one reminder per call, and the
  title in the result.
- **Read-only lists and calendars**: saving a change to an item in a
  subscribed or read-only calendar fails inside EventKit and reaches the
  client as the generic failure text. Plan 042 owns actionable errors; if it
  adds a helper for EventKit save failures, both update handlers and the
  `remove` in `reminders_delete` should use it.
- **Owner decision, 2026-10-12**: `reminders_delete` was first deferred
  ("completing covers the daily need") and then requested by the owner the
  same day: "i want reminders delete. thats valuable to me and can help me
  allow my agent to clean up my reminders". It is in this plan as Step 2b.
  `plans/README.md` still lists it as declined or deferred in three places
  (the 054 row title, the "Write verbs" decision line, and the "declined or
  deferred" list) and says "three new tools" in its cross-plan note; whoever
  maintains the index should correct those. The executor's scope there is
  the status row only.
- **Deferred, on purpose**: bulk or filtered reminder deletion (an agent
  cleans up by calling `reminders_delete` once per reminder), clearing a
  reminder's due date, other bulk operations, attendee and recurrence-rule
  editing.
- **If a field is added to create later**, add it inside
  `applyReminderFields` / `applyEventFields` and to both schemas; update then
  gets it for free. Do not add field parsing to a handler body.
- **Interaction with plan 040**: 040 makes `setPlace` throw when a rename
  would collide with another place's name. `deletePlace(named:)` still
  matches the first row by name; once 040 guarantees unique names that is
  exact.
