# Plan 039: Make every tool's MCP annotations true, and pin them with one test

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- App/Services/Capture.swift App/Services/Utilities.swift App/Services/Calendar.swift App/Services/Reminders.swift App/Services/Contacts.swift App/Services/Location.swift App/Services/Photos.swift App/Services/Shortcuts.swift iMCPTests/CallToolDispatchTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. Line numbers in this plan are from
> commit `8165d29`; if they have shifted but the quoted text is identical,
> that is not a mismatch — find the block by its `name:` string instead.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW — metadata only; no tool's behaviour, schema, or description changes
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `8165d29`, 2026-10-12

## Why this matters

Every tool iMCP advertises carries four MCP hints (`readOnlyHint`,
`destructiveHint`, `idempotentHint`, `openWorldHint`). MCP clients use them to
decide what to run without asking the user: a tool marked read-only is the one
a client auto-approves. Today 14 of the 52 tools carry a hint that is false or
missing. The serious ones: taking a photo, recording the microphone for up to
five minutes, capturing the screen, and playing a sound are all marked
**read-only**, so a client may run them silently. In the other direction,
creating a calendar event or a reminder is marked **destructive**, so clients
warn about a harmless additive action, while ringing a remote device and
overwriting a named place are marked **not** destructive. Nothing tests any of
this, so each new tool has copied whichever neighbour was nearest.

After this plan, every hint matches what the code does, there is one written
rule for choosing hints, and one test fails the moment a tool is added or
changed without the table being updated on purpose.

## Current state

### How annotations reach the client

`App/Models/Tool.swift:11-15` — the app's own `Tool` stores the SDK type
verbatim:

```swift
public struct Tool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
    let annotations: MCP.Tool.Annotations
```

`App/Controllers/ServerNetworkManager.swift:757-777` — `makeToolDefinitions(from:)`
copies them into the wire type with no transformation
(`annotations: tool.annotations`). This is the function the new test calls.

The SDK type (`modelcontextprotocol/swift-sdk` 0.12.0, `Sources/MCP/Server/Tools.swift`)
has four `Bool?` fields. **A field left out is `nil`, and the MCP spec gives
`nil` a meaning**:

| Field | Meaning when `nil` (spec default) |
|---|---|
| `readOnlyHint` | `false` — the tool may modify its environment |
| `destructiveHint` | **`true`** — the tool may destroy data (only meaningful when not read-only) |
| `idempotentHint` | `false` (only meaningful when not read-only) |
| `openWorldHint` | `true` |

So a write tool that omits `destructiveHint` is telling clients it is
destructive. That is how `contacts_create` is wrong today without containing a
wrong line.

### The rule (binding for this plan and for every future tool)

Decide each hint by reading the tool's closure, not its name.

1. **`readOnlyHint: true`** only when the call does nothing except return data
   that already exists — from a local store or from a network lookup. It is
   `false` if the call writes user data, **records from a sensor** (camera,
   microphone, screen), or **produces an effect a person can perceive** (a
   sound, a running shortcut). Internal caches and iMCP's own bookkeeping do
   not count as writes.
2. **`destructiveHint`** is written on every non-read-only tool, never on a
   read-only one. `true` when the call can replace or remove existing user
   data, or when its effect leaves this Mac and cannot be taken back (ringing
   another device, running an arbitrary shortcut). `false` when the call only
   adds something new or its effect is local and momentary.
3. **`idempotentHint`** is omitted everywhere. Write `true` only for a tool
   where a second identical call **succeeds** and leaves the same state, and
   only together with a test that proves it. No tool qualifies today.
4. **`openWorldHint`** is written on every tool. `true` when the call itself
   contacts a network service or acts on another device (Apple Maps, the
   geocoder, WeatherKit, Find My, a shortcut that can do anything). `false`
   when it only touches data already on this Mac. A local store that some
   other process syncs to iCloud later is still `false`.
5. Every tool has a non-empty `title`.

Three effect words and two reach words cover every tool, and the test in
Step 3 is written in exactly these words:

| Word | `readOnlyHint` | `destructiveHint` | `idempotentHint` |
|---|---|---|---|
| `read` | `true` | omitted | omitted |
| `add` | `false` | `false` | omitted |
| `destroy` | `false` | `true` | omitted |

| Word | `openWorldHint` |
|---|---|
| `local` | `false` |
| `open` | `true` |

### Full audit: all 52 tools

"Now" is what the source says at `8165d29` (`—` means the argument is absent,
i.e. `nil`). "Target" uses the words above. Line numbers are the
`annotations: .init(` … `)` span. **Only the 14 rows marked CHANGE are edited.**

| # | Tool | File:lines | Now R / D / I / O | Target | |
|---|---|---|---|---|---|
| 1 | `browser_history_search` | `BrowserHistory.swift:130-134` | true / — / — / false | read local | |
| 2 | `calendars_list` | `Calendar.swift:136-140` | true / — / — / false | read local | |
| 3 | `events_fetch` | `Calendar.swift:194-198` | true / — / — / false | read local | |
| 4 | `events_create` | `Calendar.swift:375-379` | — / true / — / false | add local | CHANGE |
| 5 | `events_delete` | `Calendar.swift:566-572` | false / true / true / false | destroy local | CHANGE |
| 6 | `calls_fetch` | `CallHistory.swift:76-80` | true / — / — / false | read local | |
| 7 | `capture_take_picture` | `Capture.swift:272-276` | true / — / — / false | add local | CHANGE |
| 8 | `capture_record_audio` | `Capture.swift:307-311` | true / — / — / false | add local | CHANGE |
| 9 | `capture_take_screenshot` | `Capture.swift:430-434` | true / — / — / false | add local | CHANGE |
| 10 | `contacts_me` | `Contacts.swift:152-156` | true / — / — / false | read local | |
| 11 | `contacts_search` | `Contacts.swift:190-194` | true / — / — / false | read local | |
| 12 | `contacts_update` | `Contacts.swift:262-267` | false / true / — / false | destroy local | |
| 13 | `contacts_create` | `Contacts.swift:308-312` | false / — / — / false | add local | CHANGE |
| 14 | `location_people` | `Location.swift:315-319` | true / — / — / true | read open | |
| 15 | `location_friends` | `Location.swift:345-349` | true / — / — / false | read local | |
| 16 | `location_friend` | `Location.swift:371-375` | true / — / — / false | read local | |
| 17 | `location_devices` | `Location.swift:399-403` | true / — / — / true | read open | |
| 18 | `location_ring` | `Location.swift:427-432` | false / false / — / true | destroy open | CHANGE |
| 19 | `location_history` | `Location.swift:492-496` | true / — / — / false | read local | |
| 20 | `location_visits` | `Location.swift:560-564` | true / — / — / false | read open | CHANGE |
| 21 | `location_now` | `Location.swift:612-616` | true / — / — / true | read open | |
| 22 | `location_timeline` | `Location.swift:653-657` | true / — / — / false | read open | CHANGE |
| 23 | `location_places` | `Location.swift:677-681` | true / — / — / false | read local | |
| 24 | `location_place_set` | `Location.swift:718-723` | false / false / — / false | destroy local | CHANGE |
| 25 | `maps_search` | `Maps.swift:124-128` | true / — / — / true | read open | |
| 26 | `maps_directions` | `Maps.swift:219-223` | true / — / — / true | read open | |
| 27 | `maps_explore` | `Maps.swift:310-314` | true / — / — / true | read open | |
| 28 | `maps_eta` | `Maps.swift:387-391` | true / — / — / true | read open | |
| 29 | `maps_generate` | `Maps.swift:502-506` | true / — / — / true | read open | |
| 30 | `maps_geocode` | `Maps.swift:622-626` | true / — / — / true | read open | |
| 31 | `maps_reverse_geocode` | `Maps.swift:647-651` | true / — / — / true | read open | |
| 32 | `messages_fetch` | `Messages.swift:87-91` | true / — / — / false | read local | |
| 33 | `notes_folders` | `Notes.swift:93-97` | true / — / — / false | read local | |
| 34 | `notes_search` | `Notes.swift:146-150` | true / — / — / false | read local | |
| 35 | `notes_fetch` | `Notes.swift:209-213` | true / — / — / false | read local | |
| 36 | `notifications_fetch` | `Notifications.swift:423-427` | true / — / — / false | read local | |
| 37 | `photos_search` | `Photos.swift:180-184` | true / — / — / false | read open | CHANGE |
| 38 | `photos_albums` | `Photos.swift:286-290` | true / — / — / false | read local | |
| 39 | `photos_fetch_image` | `Photos.swift:338-342` | true / — / — / false | read local | |
| 40 | `reminders_lists` | `Reminders.swift:36-40` | true / — / — / false | read local | |
| 41 | `reminders_fetch` | `Reminders.swift:83-87` | true / — / — / false | read local | |
| 42 | `reminders_create` | `Reminders.swift:179-183` | — / true / — / false | add local | CHANGE |
| 43 | `screentime_usage` | `ScreenTime.swift:78-82` | true / — / — / false | read local | |
| 44 | `screentime_web_usage` | `ScreenTime.swift:151-155` | true / — / — / false | read local | |
| 45 | `screentime_device_activity` | `ScreenTime.swift:205-209` | true / — / — / false | read local | |
| 46 | `shortcuts_list` | `Shortcuts.swift:36-40` | true / — / — / false | read local | |
| 47 | `shortcuts_run` | `Shortcuts.swift:61-65` | — / true / — / true | destroy open | CHANGE |
| 48 | `utilities_beep` | `Utilities.swift:22-26` | true / — / — / false | add local | CHANGE |
| 49 | `weather_current` | `Weather.swift:52-56` | true / — / — / true | read open | |
| 50 | `weather_daily` | `Weather.swift:84-88` | true / — / — / true | read open | |
| 51 | `weather_hourly` | `Weather.swift:118-122` | true / — / — / true | read open | |
| 52 | `weather_minute` | `Weather.swift:153-157` | true / — / — / true | read open | |

All paths are under `App/Services/`.

### Why each of the 14 changes (evidence in the code)

- **7–9, capture tools.** They switch on the camera (with optional flash and a
  `delay` of up to 60 s), record the microphone (`duration` up to 300 s,
  `Capture.swift:292-297`), or capture the screen. Rule 1: sensor recording is
  not read-only. Nothing existing is replaced and the temp file is removed
  (`Capture.swift:350,366`), so `add`, `local`.
- **48, `utilities_beep`.** Its body is `return NSSound.play(sound)`
  (`Utilities.swift:34`). A sound through the speakers is a perceivable effect:
  `add`, `local`.
- **4, `events_create`; 42, `reminders_create`.** Each builds a new
  `EKEvent`/`EKReminder` and saves it (`Calendar.swift:537`,
  `Reminders.swift:236`). Nothing existing is touched: `add`. Both also omit
  `readOnlyHint`, which rule 4's "written on every tool" discipline fixes.
- **13, `contacts_create`.** `saveRequest.add(newContact, …)`
  (`Contacts.swift:326`). Additive, but `destructiveHint` is absent, which the
  spec reads as `true`.
- **5, `events_delete`.** Claims `idempotentHint: true`, but a second identical
  call throws: `guard let anyOccurrence = self.eventStore.event(withIdentifier: identifier) else { throw ToolInputError("No event found with that identifier") }`
  (`Calendar.swift:586-588`). Rule 3: a repeat must succeed to count.
- **18, `location_ring`.** Calls `client.playSound(deviceID:)`
  (`Location.swift:451`) on a remote device over the network; the sound cannot
  be stopped from here. The repo's own design note agrees:
  `docs/plans/2026-08-23-1559-location-find-my-rebuild-plan.md:152` says
  "Annotate `readOnlyHint: false`, `destructiveHint: true`".
- **24, `location_place_set`.** Its description says "Naming a place that
  already exists moves it", and the store does
  `INSERT … ON CONFLICT(id) DO UPDATE SET name = …, latitude = …`
  (`App/Services/Location/LocationHistoryStore.swift:451-461`). It overwrites.
  The same design note (line 173) says `destructiveHint: true`.
- **37, `photos_search`.** `Photos.swift:256` calls
  `Self.lookupPlaceNames(for: assets)`, which runs
  `CLGeocoder().reverseGeocodeLocation` (`Photos.swift:481-518`) — a network
  request to Apple. Plan 049 (`plans/049-service-bugs-simplification.md`)
  keeps that lookup (owner decision 2026-10-12), so this row stays
  `read open` whichever plan lands first.
- **20, `location_visits`; 22, `location_timeline`.** *(Not in the original
  audit lead; found while reading the callers.)* Both end in
  `report(for:person:geocoder:addresses:)` (`Location.swift:1002-1025`), which
  for every stay outside a named place calls
  `Self.address(latitude:longitude:using: geocoder)` (a `CLGeocoder` reverse
  geocode) and `venueLookup.venues(…)` (an `MKLocalSearch`,
  `App/Services/Location/VenueLookup.swift:67-68`). Both are network requests
  to Apple, so `open`.
- **47, `shortcuts_run`.** Effective hints are already right (not read-only,
  destructive, open world) but `readOnlyHint` is absent. Written out so the
  table and the source agree field for field.

`contacts_update` (row 12) is already `destroy local` and is **not** edited.

### Exact current text of the 14 blocks

```swift
// App/Services/Capture.swift:272-276  (capture_take_picture)
            annotations: .init(
                title: "Take Picture",
                readOnlyHint: true,
                openWorldHint: false
            )
// App/Services/Capture.swift:307-311  (capture_record_audio)
            annotations: .init(
                title: "Record Audio",
                readOnlyHint: true,
                openWorldHint: false
            )
// App/Services/Capture.swift:430-434  (capture_take_screenshot)
            annotations: .init(
                title: "Take Screenshot",
                readOnlyHint: true,
                openWorldHint: false
            )
// App/Services/Utilities.swift:22-26  (utilities_beep)
            annotations: .init(
                title: "Play System Sound",
                readOnlyHint: true,
                openWorldHint: false
            )
// App/Services/Calendar.swift:375-379  (events_create)
            annotations: .init(
                title: "Create Event",
                destructiveHint: true,
                openWorldHint: false
            )
// App/Services/Calendar.swift:566-572  (events_delete)
            annotations: .init(
                title: "Delete Event",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
// App/Services/Reminders.swift:179-183  (reminders_create)
            annotations: .init(
                title: "Create Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
// App/Services/Contacts.swift:308-312  (contacts_create)
            annotations: .init(
                title: "Create Contact",
                readOnlyHint: false,
                openWorldHint: false
            )
// App/Services/Location.swift:427-432  (location_ring)
            annotations: .init(
                title: "Play Sound on Device",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: true
            )
// App/Services/Location.swift:560-564  (location_visits)
            annotations: .init(
                title: "Visited Places",
                readOnlyHint: true,
                openWorldHint: false
            )
// App/Services/Location.swift:653-657  (location_timeline)
            annotations: .init(
                title: "Location Timeline",
                readOnlyHint: true,
                openWorldHint: false
            )
// App/Services/Location.swift:718-723  (location_place_set)
            annotations: .init(
                title: "Name a Place",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: false
            )
// App/Services/Photos.swift:180-184  (photos_search)
            annotations: .init(
                title: "Search Photos",
                readOnlyHint: true,
                openWorldHint: false
            )
// App/Services/Shortcuts.swift:61-65  (shortcuts_run)
            annotations: .init(
                title: "Run Shortcut",
                destructiveHint: true,
                openWorldHint: true
            )
```

### Test conventions

- Tests are plain `XCTest` with `@testable import iMCP`.
- `iMCPTests/CallToolDispatchTests.swift` is the exemplar and the file to edit.
  It already holds two classes (`CallToolDispatchTests`, `ToolSchemaHygieneTests`)
  that enumerate every tool with
  `try makeToolDefinitions(from: ServiceRegistry.services)` (lines 11, 91).
  `ToolSchemaHygieneTests` (lines 86-151) is the structural model: one private
  helper that maps definitions, then loop-and-assert tests whose failure
  message names the tool.
- **Do not create a new test file.** Test files are not in a synchronized
  Xcode group; a new one needs four hand-written entries in
  `iMCP.xcodeproj/project.pbxproj` and silently never runs without them.
- **Weather is Release-only in the registry.** `ServiceRegistry.descriptors`
  appends `WeatherService.shared` inside `#if WEATHERKIT_AVAILABLE`
  (`App/Controllers/ServiceRegistry.swift:276-288`), and only the Release
  configuration defines that flag. Tests run in Debug, where the registry
  yields 48 tools. `App/Services/Weather.swift` itself is compiled in every
  configuration, so the test adds `WeatherService.shared` by hand to cover all
  52.
- CI builds with Xcode 26, which times out type-checking large literal
  fixtures. The table in Step 3 is therefore one multi-line **string**, parsed
  at run time — do not convert it to a dictionary or array-of-tuples literal.
- `swift format`: 4-space indent, 120-column limit; warnings are errors.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| The new test only | `Scripts/test.sh --only iMCPTests/ToolAnnotationTests` | all pass |
| App tests | `Scripts/test.sh --app-only` | all pass |
| Both suites | `Scripts/test.sh` | all pass |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

`-quiet` suppresses the success banner — success is exit code 0.

**Never** run `xcodebuild test -scheme iMCP` directly: the always-on watchdog
relaunches the installed app and breaks the test host. **Never**
`launchctl bootout` the always-on agent. Use `Scripts/test.sh` only.

## Scope

**In scope** (the only files you should modify):

- `App/Services/Capture.swift`
- `App/Services/Utilities.swift`
- `App/Services/Calendar.swift`
- `App/Services/Reminders.swift`
- `App/Services/Contacts.swift`
- `App/Services/Location.swift`
- `App/Services/Photos.swift`
- `App/Services/Shortcuts.swift`
- `iMCPTests/CallToolDispatchTests.swift`
- `plans/README.md` (status row only)

Within the eight service files, the **only** lines you may touch are inside the
14 `annotations: .init( … )` blocks quoted above.

**Out of scope** (do NOT touch, even though they look related):

- Any tool's closure, description, `inputSchema`, or `title`. This plan changes
  no behaviour.
- The other 38 `annotations:` blocks. They are already correct; "tidying" them
  only adds diff.
- `App/Models/Tool.swift` and `App/Controllers/ServerNetworkManager.swift` — do
  not add defaulting, validation, or a helper type for annotations. The test is
  the enforcement.
- `Photos.swift`'s reverse-geocode lookup itself — it stays (owner decision
  2026-10-12); no plan removes it.
- `contacts_update`'s merge behaviour — plan 041 owns it.
- `location_*` behaviour, error text, and the dead branch in
  `currentPosition(for:)` — plan 040 owns them.
- Tool argument validation (plan 038) and error wording (plan 042).
- `README.md`, `AGENTS.md`, `docs/` — plan 053 owns documentation.
- `iMCP.xcodeproj/project.pbxproj`.

## Git workflow

- Start from an up-to-date `main` (`git fetch origin && git switch -c advisor/039-correct-tool-annotations origin/main`).
- Two commits, conventional-commit style as in `git log`
  (e.g. `fix: bring Settings forward from the menu; stay quiet on relaunch`):
  1. `fix: correct MCP annotations on 14 tools`
  2. `test: pin every tool's annotations to one table`
- Do NOT push or open a PR unless the operator says so. `origin`
  (`cyberpapiii/iMCP`) is the only writable remote; never push to `upstream`
  (`mattt/iMCP`).

## Steps

### Step 1: Confirm the starting point

```console
grep -c 'annotations: .init(' App/Services/*.swift | awk -F: '{s+=$2} END {print s}'
grep -n 'idempotentHint' App/Services/*.swift
grep -c 'readOnlyHint: true' App/Services/Capture.swift App/Services/Utilities.swift
```

**Verify**: first prints `52`; second prints exactly one line
(`App/Services/Calendar.swift:570:                idempotentHint: true,`);
third prints `App/Services/Capture.swift:3` and `App/Services/Utilities.swift:1`.
Anything else is a STOP (the code has drifted from the audit table).

### Step 2: Edit the 14 annotation blocks

Replace each block's hint lines so it reads exactly as below. Keep the existing
`title:` line and indentation. Argument order must stay `title`,
`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint` (it is the
initializer's declared order; any other order does not compile).

`add local` — applies to `capture_take_picture`, `capture_record_audio`,
`capture_take_screenshot` (`Capture.swift`), `utilities_beep`
(`Utilities.swift`), `events_create` (`Calendar.swift`), `reminders_create`
(`Reminders.swift`), `contacts_create` (`Contacts.swift`):

```swift
            annotations: .init(
                title: "<unchanged>",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: false
            )
```

`destroy local` — `events_delete` (`Calendar.swift`; this is the block losing
its `idempotentHint: true,` line) and `location_place_set` (`Location.swift`):

```swift
            annotations: .init(
                title: "<unchanged>",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
```

`destroy open` — `location_ring` (`Location.swift`) and `shortcuts_run`
(`Shortcuts.swift`):

```swift
            annotations: .init(
                title: "<unchanged>",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: true
            )
```

`read open` — `location_visits`, `location_timeline` (`Location.swift`) and
`photos_search` (`Photos.swift`):

```swift
            annotations: .init(
                title: "<unchanged>",
                readOnlyHint: true,
                openWorldHint: true
            )
```

Add no comments to the service files; the rule lives with the test (Step 3).

**Verify**:

```console
grep -c 'idempotentHint' App/Services/*.swift | awk -F: '{s+=$2} END {print s}'
grep -c 'readOnlyHint' App/Services/*.swift | awk -F: '{s+=$2} END {print s}'
grep -c 'openWorldHint' App/Services/*.swift | awk -F: '{s+=$2} END {print s}'
grep -c 'destructiveHint' App/Services/*.swift | awk -F: '{s+=$2} END {print s}'
grep -c 'readOnlyHint: true' App/Services/Capture.swift App/Services/Utilities.swift
git diff --stat
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```

→ `0`, `52`, `52`, `12`, `…Capture.swift:0` and `…Utilities.swift:0`, a diff
stat listing exactly the eight service files, and `exit=0`.

(`12` = the twelve non-read-only tools: seven `add` plus five `destroy`,
counting the untouched `contacts_update`.)

### Step 3: Add the registry-wide test

Append this class to the end of `iMCPTests/CallToolDispatchTests.swift`. The
doc comment is the project's written rule — keep it with the table.

```swift
/// Clients decide what to run without asking from these hints, so each one
/// has to be true. Decide by reading the tool's closure, not its name:
///
/// - `read`: only returns data that already exists. Writing user data,
///   recording from the camera, microphone, or screen, or doing anything a
///   person can perceive (a sound, a running shortcut) is not a read.
/// - `add`: creates something new, or has a local, momentary effect.
/// - `destroy`: can replace or remove existing data, or has an effect that
///   leaves this Mac and cannot be taken back.
/// - `open`: the call itself contacts a network service or another device.
///   `local`: it only touches data already on this Mac.
///
/// `idempotentHint` stays unset: claim it only for a tool whose second
/// identical call succeeds and changes nothing, with a test that proves it.
final class ToolAnnotationTests: XCTestCase {
    private static let table = """
        browser_history_search read local
        calendars_list read local
        calls_fetch read local
        capture_record_audio add local
        capture_take_picture add local
        capture_take_screenshot add local
        contacts_create add local
        contacts_me read local
        contacts_search read local
        contacts_update destroy local
        events_create add local
        events_delete destroy local
        events_fetch read local
        location_devices read open
        location_friend read local
        location_friends read local
        location_history read local
        location_now read open
        location_people read open
        location_place_set destroy local
        location_places read local
        location_ring destroy open
        location_timeline read open
        location_visits read open
        maps_directions read open
        maps_eta read open
        maps_explore read open
        maps_generate read open
        maps_geocode read open
        maps_reverse_geocode read open
        maps_search read open
        messages_fetch read local
        notes_fetch read local
        notes_folders read local
        notes_search read local
        notifications_fetch read local
        photos_albums read local
        photos_fetch_image read local
        photos_search read open
        reminders_create add local
        reminders_fetch read local
        reminders_lists read local
        screentime_device_activity read local
        screentime_usage read local
        screentime_web_usage read local
        shortcuts_list read local
        shortcuts_run destroy open
        utilities_beep add local
        weather_current read open
        weather_daily read open
        weather_hourly read open
        weather_minute read open
        """

    func testEveryToolAnnotationMatchesTheTable() throws {
        // Weather is registered only in Release builds; its tools ship all the same.
        var services = ServiceRegistry.services
        if !services.contains(where: { $0 is WeatherService }) {
            services.append(WeatherService.shared)
        }
        let definitions = try makeToolDefinitions(from: services)

        var expected: [String: (effect: String, reach: String)] = [:]
        for line in Self.table.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            XCTAssertEqual(fields.count, 3, "Malformed row: \(line)")
            XCTAssertTrue(["read", "add", "destroy"].contains(fields[1]), "Unknown effect: \(line)")
            XCTAssertTrue(["local", "open"].contains(fields[2]), "Unknown reach: \(line)")
            expected[fields[0]] = (fields[1], fields[2])
        }

        XCTAssertEqual(
            Set(definitions.map(\.localTool.name)),
            Set(expected.keys),
            "Add, rename, or remove the tool's row in the table"
        )
        for definition in definitions {
            let name = definition.localTool.name
            guard let row = expected[name] else { continue }
            let hints = definition.mcpTool.annotations
            let destructive: Bool? = row.effect == "read" ? nil : row.effect == "destroy"
            XCTAssertEqual(hints.readOnlyHint, row.effect == "read", "\(name) readOnlyHint")
            XCTAssertEqual(hints.destructiveHint, destructive, "\(name) destructiveHint")
            XCTAssertNil(hints.idempotentHint, "\(name) idempotentHint")
            XCTAssertEqual(hints.openWorldHint, row.reach == "open", "\(name) openWorldHint")
            XCTAssertFalse((hints.title ?? "").isEmpty, "\(name) has no title")
        }
    }
}
```

Notes for the executor:

- The `XCTAssertEqual` calls compare an optional (`Bool?`) hint with a plain
  `Bool`; Swift promotes the right-hand side. That is intended — it makes a
  missing (`nil`) `readOnlyHint` or `openWorldHint` fail, which enforces
  "written on every tool".
- `fields[1]` is only reached after the `count == 3` assertion; with the table
  as given every row has three fields. Do not restructure the table to make
  that "safer".

**Verify**: `Scripts/test.sh --only iMCPTests/ToolAnnotationTests` → the one
test passes.

Then prove the test can fail (it must not be vacuous): temporarily change the
`utilities_beep` row in the table to `utilities_beep read local`, re-run the
same command, and confirm it **fails** naming `utilities_beep readOnlyHint` and
`utilities_beep destructiveHint`. Restore the row to `utilities_beep add local`
and confirm it passes again.

### Step 4: Run the full gate

```console
swift format -i -r .
swift format lint --strict --recursive . ; echo "exit=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh ; echo "exit=$?"
git status --short
```

**Verify**: three `exit=0` lines, and `git status --short` lists only the eight
service files and `iMCPTests/CallToolDispatchTests.swift` (plus
`plans/README.md` once you update it). If `swift format -i` touched any other
file, revert that file (`git checkout -- <file>`) — it is unrelated drift.

## Test plan

- **New**: one class, `ToolAnnotationTests`, with one test,
  `testEveryToolAnnotationMatchesTheTable`, appended to
  `iMCPTests/CallToolDispatchTests.swift`. It covers:
  - every one of the 52 tools has a row, and no row names a tool that does not
    exist (set equality — a new or renamed tool fails until its row is added);
  - each hint equals the row's meaning, including the regressions this plan
    fixes (capture and beep not read-only; creates not destructive; ring and
    place-set destructive; `events_delete` not idempotent; `photos_search`,
    `location_visits`, `location_timeline` open-world);
  - `readOnlyHint` and `openWorldHint` are written on every tool,
    `destructiveHint` on exactly the non-read-only ones, `idempotentHint` on
    none;
  - every tool has a title.
- **Structural pattern**: `ToolSchemaHygieneTests` in the same file
  (lines 86-151).
- **No behaviour tests are added or changed** — no behaviour changes.
- Verification: `Scripts/test.sh` → all pass, including 1 new test.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c 'idempotentHint' App/Services/*.swift | awk -F: '{s+=$2} END {print s}'` → `0`
- [ ] `grep -c 'readOnlyHint' App/Services/*.swift | awk -F: '{s+=$2} END {print s}'` → `52`
- [ ] `grep -c 'openWorldHint' App/Services/*.swift | awk -F: '{s+=$2} END {print s}'` → `52`
- [ ] `grep -c 'destructiveHint' App/Services/*.swift | awk -F: '{s+=$2} END {print s}'` → `12`
- [ ] `grep -c 'readOnlyHint: true' App/Services/Capture.swift App/Services/Utilities.swift` → both `0`
- [ ] `grep -c 'final class ToolAnnotationTests' iMCPTests/CallToolDispatchTests.swift` → `1`
- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `Scripts/test.sh` exits 0, with `testEveryToolAnnotationMatchesTheTable` passing
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `git diff --stat origin/main -- App/Services` shows only annotation lines changed (about +8 / −1 lines across eight files; no closure, schema, or description line appears in `git diff`)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row for 039 updated

## STOP conditions

Stop and report back (do not improvise) if:

- Step 1's counts differ (not 52 tools, or `idempotentHint` appears somewhere
  other than `Calendar.swift`'s `events_delete`). A tool was added, removed, or
  re-annotated since the audit; the table needs a human decision for it.
- Any of the 14 quoted blocks does not match the live code.
- `photos_search` no longer calls `lookupPlaceNames` / `CLGeocoder`. No plan
  removes that lookup (owner decision 2026-10-12: the place-name feature
  stays), so its absence means the code drifted. Report it.
- `location_visits` / `location_timeline` no longer reach
  `Self.address(…using: geocoder)` or `venueLookup.venues` (plan 040 or 047
  changed them). Same handling: report; do not guess the row.
- The test crashes, hangs, or errors while touching `WeatherService.shared` in
  the Debug test host (WeatherKit entitlement). Do **not** delete the weather
  rows. Report it; the fallback a reviewer will likely approve is to drop the
  three `services.append` lines and replace the set-equality assertion with
  "registry names ⊆ table names, and every table name missing from the
  registry starts with `weather_`".
- The Xcode 26 CI build reports a type-check timeout in
  `ToolAnnotationTests` — report it; do not split the table into literals.
- The new test fails for a tool **after** Step 2 was applied exactly. That
  means the audit table in this plan is wrong for that tool; report the tool
  and the actual hints instead of editing the table to match the code.
- You believe a hint in the target table is wrong after reading a closure.
  Report the tool and the evidence; do not change the rule on your own.
- A step's verification fails twice after a reasonable fix attempt, or the fix
  appears to need a file outside the in-scope list.

## Maintenance notes

For the human/agent who owns this code after the change lands:

- **Adding a tool**: the test fails until the tool has a row. Pick the two
  words from the rule in the test's doc comment by reading the closure, then
  write the hints to match (`readOnlyHint` and `openWorldHint` always;
  `destructiveHint` only when not read-only).
- **Client-visible effect**: clients that auto-approve read-only tools will
  start asking before the three capture tools and `utilities_beep`. That is the
  point. Clients that highlight destructive tools will stop flagging
  `events_create`, `reminders_create`, `contacts_create` and start flagging
  `location_ring` and `location_place_set`. Connected clients pick this up on
  their next `tools/list`.
- **Judgement calls a reviewer should look at**:
  - `events_delete` loses `idempotentHint`. The MCP spec's wording ("no
    additional effect on its environment") could be read as still true, since
    the second call changes nothing. This project uses the stricter "the
    repeat succeeds" reading because the hint is consumed as "safe to retry
    blindly" and the retry returns an error.
  - `location_ring` is `destroy` although it deletes nothing — it is the "leaves
    this Mac and cannot be taken back" half of the rule, and matches the
    repo's own design note.
  - `location_now` and the other Find My reads stay `read`: a `refresh` asks
    Apple to wake a device, which this rule does not count as a write.
- **Plan 049** keeps the photo reverse-geocode lookup (owner decision
  2026-10-12), so `photos_search` stays `read open`.
- **Plans 040/047** touch `location_visits` / `location_timeline`. If either
  stops geocoding or venue lookup on the read path, flip those rows to
  `read local`.
- **Plan 054** (write verbs) adds tools; each needs a row, and a delete-style
  tool is `destroy`.
- **Not done here, on purpose**: no helper type, enum, or factory for
  annotations in `App/`. Three words in a test table are enough; a production
  abstraction would add more code than it removes from the 52 call sites.
- This plan does not install the app. After tests pass, the local-dev command
  is `Scripts/install-local.sh run` — run it only if the operator asks.
