# Plan 038: Validate tool arguments in one place so a bad number or enum can no longer crash the app or be silently ignored

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- App/Models/Value+Number.swift App/Models/FetchPolicy.swift App/Services/Weather.swift App/Services/Calendar.swift App/Services/Reminders.swift App/Services/Capture.swift App/Services/Maps.swift App/Services/Photos.swift App/Services/ScreenTime.swift App/Services/Contacts.swift App/Services/Notes.swift App/Services/Location.swift App/Services/Messages.swift App/Services/CallHistory.swift App/Services/BrowserHistory.swift App/Services/Notifications.swift iMCPTests/AppModelTests.swift iMCPTests/ToolErrorSanitizationTests.swift iMCPTests/PhotoServiceTests.swift iMCPTests/CallToolDispatchTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED — many small edits across ten service files; each is mechanical, but several turn a silent fallback into an error, which is an intended behaviour change
- **Depends on**: plans/037-isolate-tests-from-real-state.md
- **Category**: bug
- **Planned at**: commit `8165d29`, 2026-10-12

## Why this matters

iMCP is a macOS menu-bar MCP server: AI clients call its tools with JSON
arguments. The dispatcher hands those arguments to each tool unchecked, and the
`minimum` / `maximum` / `enum` values in each tool's schema are advice to the
client, not something the server enforces. Today a single out-of-range number
crashes the whole app (integer overflow in alarm maths, `Int(1e300)`,
`UInt32(-1)`), a huge `limit` or `duration` runs unbounded, and a misspelled
enum value or list name is silently replaced with a default, so the client gets
a plausible answer to a question it did not ask.

Every service parses numbers its own way (six hand-rolled variants). This plan
adds four small shared parsers, routes every site through them, deletes the
hand-rolled copies, and makes each schema advertise the limit the server really
applies.

The rule after this plan, to follow for any new tool:

- **Sizes and counts** (`limit`, `duration`, `maxDimension`, `radius`, …):
  a value outside the range is **clamped** into it; a value of the wrong JSON
  type **throws** `ToolInputError`.
- **Identifiers, coordinates, enums, names, dates**: anything invalid
  **throws** `ToolInputError`. Never substitute a default for a value the
  caller did send.
- A missing key (or JSON `null`) always means "use the default".

## Current state

All paths are relative to the repo root. Line numbers are from commit `8165d29`.

### How arguments arrive

```swift
// App/Controllers/ServerNetworkManager.swift:583-586
            do {
                let result = try await definition.localTool.callAsFunction(
                    params.arguments ?? [:]
                )
```

`arguments` is `[String: Value]`. `Value` is the MCP SDK's JSON enum
(`.int(Int)`, `.double(Double)`, `.string`, `.bool`, `.array`, `.object`,
`.null`), re-exported by `App/Models/Value.swift`. The SDK decodes `40` as
`.int` and `40.0` as `.double`; `value.intValue` answers nil for `.double`.

### How errors reach the client

```swift
// App/Controllers/ToolErrorResponse.swift:30-38
struct ToolInputError: ClientFacingError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
```

Only errors conforming to `ClientFacingError` reach the client verbatim;
everything else becomes "Tool execution failed. See iMCP logs for details."
Bad arguments must throw `ToolInputError`. Its message may echo the caller's
own argument but nothing else (no paths, no system error text).
`FetchPolicy.Error` is also client-facing.

### The existing shared pieces

```swift
// App/Models/Value+Number.swift (whole file)
import MCP

extension Value {
    /// A JSON number as a `Double`, whether the client sent `40` or `40.0`.
    /// ...
    public var numberValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }
}
```

```swift
// App/Extensions/Foundation+Extensions.swift:142-147
extension Int {
    /// Named to avoid SwiftUI's package `clamped(to:)`.
    func bounded(to range: ClosedRange<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(self, range.upperBound))
    }
}
```

```swift
// App/Models/FetchPolicy.swift:75-88
    static func parseLimit(
        from arguments: [String: Value],
        defaultLimit: Int,
        hardCap: Int = 500,
        hasSearchTerm: Bool = false
    ) -> (requested: Int, fetch: Int) {
        let requested = max(arguments["limit"]?.intValue ?? defaultLimit, 0)
        let fetch = widenedSearchFetchLimit(
            requestedLimit: requested,
            hasSearchTerm: hasSearchTerm,
            hardCap: hardCap
        )
        return (requested, fetch)
    }
```

`fetch` is capped at `hardCap`; **`requested` has no ceiling**. These callers
use `requested` directly as the row limit:
`App/Services/Messages.swift:118`, `App/Services/CallHistory.swift:107`,
`App/Services/ScreenTime.swift:89` and `:161`, `App/Services/Location.swift:510`.

The exemplar for "reject an unknown enum value" already in the repo:

```swift
// App/Services/Calendar.swift:89-98
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

### Defects, by class

**A. Crashes (a Swift trap kills the app; `do/catch` cannot stop it)**

```swift
// App/Services/Calendar.swift:469-472   (events_create, relative alarm)
                    case "relative":
                        if case .int(let minutes) = config["minutes"] {
                            alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                        }
```

```swift
// App/Services/Reminders.swift:229-234   (reminders_create)
            if case .array(let alarmMinutes) = arguments["alarms"] {
                reminder.alarms = alarmMinutes.compactMap {
                    guard case .int(let minutes) = $0 else { return nil }
                    return EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                }
            }
```

`-minutes * 60` is `Int` arithmetic: it overflows and traps for `minutes`
beyond about ±1.5e17, and `-minutes` traps for `Int.min`.

```swift
// App/Services/Capture.swift:462-463   (capture_take_screenshot)
            let displayId = arguments["displayId"]?.intValue.map { CGDirectDisplayID($0) }
            let windowId = arguments["windowId"]?.intValue.map { CGWindowID($0) }
```

Both types are `UInt32`; `UInt32(-1)` and `UInt32(5_000_000_000)` trap. The
schema (`Capture.swift:404-412`) declares both as `.number(... minimum: 0)`.

```swift
// App/Services/Weather.swift:24-37
    private static func clampedIntArg(
        _ arguments: [String: Value],
        key: String,
        default defaultValue: Int,
        range: ClosedRange<Int>
    ) -> Int {
        var value = defaultValue
        if case let .int(requested) = arguments[key] {
            value = requested
        } else if case let .double(requested) = arguments[key] {
            value = Int(requested)
        }
        return value.bounded(to: range)
    }
```

`Int(1e300)`, `Int(.nan)` and `Int(.infinity)` trap. Used at `Weather.swift:91`,
`:125`, `:160`. (`Weather.swift` is compiled in Debug even though the service is
only registered in Release, so the build still checks your edit.)

```swift
// App/Services/Location.swift:500   (location_history)
            let interval = arguments["intervalMinutes"]?.intValue.map { max($0, 0) * 60 }
// App/Services/Location.swift:579   (location_visits)  and  :663 (location_timeline), identical
            let dwell = TimeInterval(max(arguments["minimumMinutes"]?.intValue ?? 10, 0) * 60)
```

Same `* 60` overflow. (Not in the original audit list; found while verifying it.)

**B. Unbounded sizes**

```swift
// App/Services/Capture.swift:322   (capture_record_audio; schema :292-297 says 1...300)
            let duration = arguments["duration"].flatMap { Double($0) } ?? 10.0
// App/Services/Capture.swift:455-460   (screenshot; schema :421-426 has minimum 1, no maximum)
            var maxDimension = 2048
            if let requestedDimension = arguments["maxDimension"]?.intValue,
                requestedDimension > 0
            {
                maxDimension = requestedDimension
            }
// App/Services/Capture.swift:652   (take_picture; schema :219-224 says 0...1)
        let quality = arguments["quality"]?.numberValue ?? 0.8
// App/Services/Capture.swift:674-678   (take_picture; delay schema :257-262 says 0...60)
        let delay = arguments["delay"]?.numberValue ?? 1.0
        var maxDimension = 2048
        if let requestedDimension = arguments["maxDimension"]?.intValue, requestedDimension > 0 {
            maxDimension = requestedDimension
        }
```

`duration` feeds `recorder.record(forDuration:)` and
`Task.sleep(for: .seconds(duration + 5))` (`:336`, `:348`, `:370`); `delay`
feeds `Task.sleep(for: .seconds(delay))` (`:749`, `:770`). A value of `1e12`
holds the microphone or the camera gate open indefinitely.

Hand-rolled limits, each different:

```swift
// App/Services/Reminders.swift:111
            let limit = max(arguments["limit"]?.intValue ?? 100, 0)
// App/Services/Notes.swift:154        (interpolated into AppleScript at :173)
            let limit = max(arguments["limit"]?.intValue ?? defaultLimit, 1)
// App/Services/Maps.swift:324         (maps_explore)
            let limit = max(1, arguments["limit"]?.intValue ?? defaultSearchLimit)
// App/Services/Contacts.swift:230-233
            var limit = 20
            if case .int(let requestedLimit) = arguments["limit"], requestedLimit > 0 {
                limit = requestedLimit.bounded(to: 1 ... 100)
            }
// App/Services/Photos.swift:219-222   (schema :160-164 has no maximum)
            var limit = 30
            if case .int(let requestedLimit) = arguments["limit"], requestedLimit > 0 {
                limit = requestedLimit.bounded(to: 1 ... 100)
            }
// App/Services/Photos.swift:350-355   (schema :328-333 has no maximum)
            var maxDimension = 2048
            if case .int(let requestedDimension) = arguments["maxDimension"],
                requestedDimension > 0
            {
                maxDimension = requestedDimension.bounded(to: 1 ... 2048)
            }
// App/Services/Maps.swift:516-517     (maps_generate; validated afterwards at :520-526)
            let width = arguments["width"]?.intValue ?? Int(defaultMapImageSize.width)
            let height = arguments["height"]?.intValue ?? Int(defaultMapImageSize.height)
```

All of them silently use the default when the client sends `40.0` or `"40"`.

**C. Silent enum fallback**

```swift
// App/Services/Maps.swift:20-51
func mapsMapType(from value: String?) -> MKMapType {
    switch value {
    case "satellite":
        return .satellite
    case "hybrid":
        return .hybrid
    case "mutedStandard":
        return .mutedStandard
    default:
        return .standard
    }
}

func mapsTransportType(
    from value: String?,
    default defaultType: MKDirectionsTransportType
) -> MKDirectionsTransportType {
    switch value {
    case "automobile":
        return .automobile
    ...
    case "any":
        return .any
    default:
        return defaultType
    }
}
```

Call sites: `Maps.swift:257-261` (maps_directions), `:414-418` (maps_eta),
`:518` (maps_generate). Both callers pass `default: .automobile`. With
`transportType: "bicycle"` the route is computed by car and, on failure,
`MapsError.noRoute(mode: requestedMode)` (`:270`, `:276`) reports the bogus mode.

```swift
// App/Services/Maps.swift:550-554   (maps_generate, showPointsOfInterest array)
            case let .array(poiTypes):
                let categories = poiTypes.compactMap { $0.stringValue }.compactMap {
                    MKPointOfInterestCategory.from(string: $0)
                }
                filter = categories.isEmpty ? .excludingAll : .init(including: categories)
```

```swift
// App/Services/Photos.swift:201-213
            let mediaType = arguments["mediaType"]?.stringValue ?? "any"
            switch mediaType {
            case "image":
                predicates.append(
                    NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                )
            case "video":
                predicates.append(
                    NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
                )
            default:
                break
            }
```

```swift
// App/Services/ScreenTime.swift:90 and :95
            let groupBy = arguments["groupBy"]?.stringValue ?? "app"
            ...
            if groupBy == "day" {
```

`App/Services/Capture.swift` has nine copies of this shape (`:317-321`,
`:323-327`, `:440-444`, `:445-448`, `:449-453`, `:647-651`, `:653-657`,
`:658-662`, `:663-667`, `:668-670`), for example:

```swift
// App/Services/Capture.swift:440-444
            let contentType =
                ScreenCaptureContentType(
                    rawValue: arguments["contentType"]?.stringValue
                        ?? ScreenCaptureContentType.default.rawValue
                ) ?? .display
```

Every enum involved (`AudioFormat`, `AudioQuality`, `ImageFormat`,
`SessionPreset`, `CaptureDeviceType`, `CaptureDevicePosition`, `FlashMode` in
`App/Extensions/AVFoundation+Extensions.swift`; `ScreenCaptureContentType`,
`ScreenCaptureQuality` in `App/Extensions/ScreenCaptureKit+Extensions.swift`) is
declared `: String, Hashable, CaseIterable` with a `static let default`, and in
every case the `??` fallback equals that `default`. The one exception is the
screenshot `format`, whose default is `ImageFormat.png` (`Capture.swift:447`),
not `ImageFormat.default` (which is `.jpeg`).

**D. Dates and names silently ignored**

```swift
// App/Services/Photos.swift:190-199
            if let startDate = try FetchPolicy.parseDate(
                arguments["startDate"]?.stringValue,
                asEnd: false
            ) {
                predicates.append(NSPredicate(format: "creationDate >= %@", startDate as NSDate))
            }

            if let endDate = try FetchPolicy.parseDate(arguments["endDate"]?.stringValue, asEnd: true) {
                predicates.append(NSPredicate(format: "creationDate <= %@", endDate as NSDate))
            }
```

A non-string date is dropped (`?.stringValue` is nil) and an inverted range
returns `[]`. `FetchPolicy.parse(from:)` (`FetchPolicy.swift:90-136`) throws for
both and also parses `limit`.

```swift
// App/Services/Reminders.swift:205-209   (reminders_create)
            if case .string(let dueDateStr) = arguments["due"],
                let parsedDueDate = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: dueDateStr
                )
            {
```

An unparseable `due` creates the reminder with no due date. `reminders_fetch`
already uses the throwing pair `FetchPolicy.dateString` + `FetchPolicy.parseDate`
(`Reminders.swift:103-110`). `FetchPolicy.parseRawDate(_:)`
(`FetchPolicy.swift:49-59`) returns the same `(date:, isDateOnly:)` tuple the
block needs and throws `FetchPolicy.Error.invalidDate`.

```swift
// App/Services/Reminders.swift:91-101   (reminders_fetch)
            var reminderLists = self.eventStore.calendars(for: .reminder)
            if case .array(let listNames) = arguments["lists"],
                !listNames.isEmpty
            {
                let requestedNames = Set(
                    listNames.compactMap { $0.stringValue?.lowercased() }
                )
                reminderLists = reminderLists.filter {
                    requestedNames.contains($0.title.lowercased())
                }
            }
```

```swift
// App/Services/Calendar.swift:202-208   (events_fetch — the same code, same defect)
            var calendars = self.eventStore.calendars(for: .event)
            if case .array(let calendarNames) = arguments["calendars"],
                !calendarNames.isEmpty
            {
                let requestedNames = Set(calendarNames.compactMap { $0.stringValue?.lowercased() })
                calendars = calendars.filter { requestedNames.contains($0.title.lowercased()) }
            }
```

A misspelled name yields an **empty** calendars array, which is then passed to
an EventKit predicate. EventKit documents `nil` as "all calendars" and does not
document the empty array, so a typo may return everything or nothing. The repo
already has the right error for a wrong name:

```swift
// App/Services/Reminders.swift:257-271
func requireSingleCalendar<Match>(
    _ matches: [Match],
    named name: String,
    kind: String,
    listTool: String
) throws -> Match {
    guard matches.count == 1, let match = matches.first else {
        throw ToolInputError(
            matches.isEmpty
                ? "\(kind) not found: \(name). Call \(listTool) for valid names."
                : "\(kind) name is ambiguous: \(name). Rename one so each name is unique."
        )
    }
    return match
}
```

**E. Coordinates and distances unvalidated**

Seven sites read `latitude`/`longitude` with `numberValue` and use them raw:
`App/Services/Weather.swift:14-22`, `App/Services/Maps.swift:137-149`
(maps_search region), `:316-333` (maps_explore), `:393-406` (maps_eta),
`:508-535` (maps_generate, plus `latitudeDelta`/`longitudeDelta`), `:653-660`
(maps_reverse_geocode), `:820-828` (`getMapItem`, used by maps_directions).
`NaN`, latitude `999`, a negative radius, or a zero/negative delta go straight
into MapKit, which can raise an uncatchable Objective-C exception for an
invalid region. `radius` is read raw at `Maps.swift:141` and `:323`.

### Tests that pin today's behaviour (you will edit these)

- `iMCPTests/AppModelTests.swift:224-229` `testMapImageDimensionBounds` — tests
  `isValidMapImageDimension`, which Step 8 deletes.
- `iMCPTests/AppModelTests.swift:386-395` `testCalendarEventsFetchLimitCapsAt500`
  — calls `calendarEventsFetchLimit`, which becomes `throws` in Step 2.
- `iMCPTests/PhotoServiceTests.swift:48-59` two `mapsTransportType` tests; the
  second asserts the silent fallback (`"bicycle"` → `.automobile`) that Step 8
  removes.
- `iMCPTests/AppModelTests.swift:473-481` `ToolResultTests
  .testNumericArgumentsAcceptOnlyIntegerAndDoubleValues` — the model for the
  new helper tests.
- `iMCPTests/ToolErrorSanitizationTests.swift:169-193`
  `ClientFacingToolErrorTests` — tests `requireSingleCalendar` with plain
  `[String]`; the model for the EventKit helper tests.
- `iMCPTests/CallToolDispatchTests.swift:88-110` `ToolSchemaHygieneTests` with
  its `inputSchemas()` helper — the model for the schema test. Its doc comment
  says "Every byte of every schema lands in a client's context on every
  session": add only the schema keys this plan names.

### Conventions

- Swift 6 strict concurrency; **warnings are errors** (a `var` that is no
  longer mutated fails the build — change it to `let`).
- `swift format`: 4-space indent, 120-column limit.
- Tests are plain `XCTest`. Test files are **not** in a synchronized group: a
  new test file would need four hand-made `project.pbxproj` entries and would
  otherwise silently never run. **Add every test to an existing file.** Files
  under `App/` are picked up automatically.
- CI builds with Xcode 26 (Debug); the local toolchain may be Xcode 27 beta.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 (`-quiet` prints nothing on success) |
| All tests | `Scripts/test.sh` | exit 0, both suites pass |
| App tests only | `Scripts/test.sh --app-only` | exit 0 |
| One test class | `Scripts/test.sh --only iMCPTests/<ClassName>` | exit 0 (`--only` is passed as `-only-testing:` and implies app-only) |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

Never run `xcodebuild test -scheme iMCP` directly: a watchdog relaunches the
installed app and breaks the test host. `Scripts/test.sh` stops the installed
app and restores it afterwards. Never `launchctl bootout` anything.

## Scope

**In scope** (the only files you should modify):

- `App/Models/Value+Number.swift`
- `App/Models/FetchPolicy.swift`
- `App/Services/Weather.swift`
- `App/Services/Calendar.swift`
- `App/Services/Reminders.swift`
- `App/Services/Capture.swift`
- `App/Services/Maps.swift`
- `App/Services/Photos.swift`
- `App/Services/ScreenTime.swift`
- `App/Services/Contacts.swift`
- `App/Services/Notes.swift`
- `App/Services/Location.swift` — three lines (`:500`, `:579`, `:663`) and one schema entry (`:485-488`) only
- `App/Services/Messages.swift`, `App/Services/CallHistory.swift`,
  `App/Services/BrowserHistory.swift`, `App/Services/Notifications.swift` —
  the `"limit"` schema entry only
- `iMCPTests/AppModelTests.swift`
- `iMCPTests/ToolErrorSanitizationTests.swift`
- `iMCPTests/PhotoServiceTests.swift`
- `iMCPTests/CallToolDispatchTests.swift`

**Out of scope** (do NOT touch, even though they look related):

- `location_place_set` validation (`Location.swift:~720-756`), the
  `ORDER BY`/`LIMIT` behaviour of `location_history`, and anything else in
  `Location.swift` — plan 040.
- Image encoding (PNG/JPEG/TIFF) in Capture and Maps, the
  `withCheckedThrowingContinuation` blocks in `Maps.swift`, the radius-as-diameter
  bug at `Maps.swift:141-147`, `NSScreen.main?.backingScaleFactor` at
  `Maps.swift:538` — plan 049. Keep the continuation blocks byte-for-byte.
- Replacing `NSError(domain:code:userInfo:)` throws, or changing which errors
  are client-facing — plan 042.
- Tool `annotations:` (`readOnlyHint` etc.) — plan 039.
- The Calendar alarm loop's other silent skips (`Calendar.swift:474-517`:
  date-only absolute alarm, unknown alarm type, proximity alarm coordinates).
  Only the `"relative"` branch changes here.
- `iMCP.xcodeproj/project.pbxproj` — no new files are needed.
- Anything under `Scripts/`, `CLI/`, `App/Views/`.

## Git workflow

- Start from an up-to-date `main` with plan 037 merged. Branch:
  `advisor/038-validate-tool-arguments`.
- Conventional commits, one per step, e.g.
  `fix(capture): reject out-of-range display and window ids`,
  `refactor(weather): use the shared integer argument parser`. Repo examples:
  `fix: bring Settings forward from the menu; stay quiet on relaunch`,
  `feat(messages): add conversations, attachments, and chatId to messages_fetch`.
- Do NOT push or open a PR unless the operator asks. `origin`
  (`cyberpapiii/iMCP`) is the only writable remote; never push to `upstream`
  (`mattt/iMCP`).

## Steps

### Step 1: Add the shared parsers and their tests

Edit `App/Models/Value+Number.swift`. Add `import CoreLocation` above
`import MCP`. Inside the existing `extension Value`, after `numberValue`, add:

```swift
    /// A whole JSON number as an `Int`, whether the client sent `40` or `40.0`.
    ///
    /// Fractional, non-finite, and out-of-range numbers answer nil. `Int(_:)`
    /// on such a `Double` traps, so no tool argument goes through it.
    public var wholeNumberValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(exactly: value)
        default: return nil
        }
    }
```

Below the extension, at file scope, add:

```swift
// Tool-argument parsing. A missing key or JSON null takes the default. A size
// or count outside its range is clamped into it; a value of the wrong type
// throws. Identifiers, coordinates, and enums never fall back: anything
// invalid throws, so a typo cannot quietly answer a different question.

private func present(_ arguments: [String: Value], _ key: String) -> Value? {
    guard let value = arguments[key], value != .null else { return nil }
    return value
}

func clampedIntArgument(
    _ arguments: [String: Value],
    _ key: String,
    default defaultValue: Int,
    in range: ClosedRange<Int>
) throws -> Int {
    guard let value = present(arguments, key) else { return defaultValue }
    guard let requested = value.wholeNumberValue else {
        throw ToolInputError("\(key) must be a whole number")
    }
    return requested.bounded(to: range)
}

func clampedNumberArgument(
    _ arguments: [String: Value],
    _ key: String,
    default defaultValue: Double,
    in range: ClosedRange<Double>
) throws -> Double {
    guard let value = present(arguments, key) else { return defaultValue }
    guard let requested = value.numberValue, !requested.isNaN else {
        throw ToolInputError("\(key) must be a number")
    }
    return min(max(requested, range.lowerBound), range.upperBound)
}

/// A string argument naming one case of `Choice`. The error lists the valid names.
func enumArgument<Choice: RawRepresentable & CaseIterable>(
    _ arguments: [String: Value],
    _ key: String,
    default defaultValue: Choice
) throws -> Choice where Choice.RawValue == String {
    guard let value = present(arguments, key) else { return defaultValue }
    guard let name = value.stringValue, let choice = Choice(rawValue: name) else {
        let names = Choice.allCases.map(\.rawValue).joined(separator: ", ")
        throw ToolInputError("Invalid \(key). Expected one of: \(names).")
    }
    return choice
}

/// A required latitude/longitude pair that names a real point on Earth.
func coordinateArgument(
    _ arguments: [String: Value],
    latitude latitudeKey: String = "latitude",
    longitude longitudeKey: String = "longitude"
) throws -> CLLocationCoordinate2D {
    guard let latitude = arguments[latitudeKey]?.numberValue,
        let longitude = arguments[longitudeKey]?.numberValue
    else {
        throw ToolInputError("\(latitudeKey) and \(longitudeKey) are required numbers")
    }
    let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    guard latitude.isFinite, longitude.isFinite, CLLocationCoordinate2DIsValid(coordinate) else {
        throw ToolInputError(
            "\(latitudeKey) must be between -90 and 90 and \(longitudeKey) between -180 and 180"
        )
    }
    return coordinate
}
```

Then add tests to `iMCPTests/AppModelTests.swift`, inside the existing
`final class ToolResultTests` (starts at line 473), directly after
`testNumericArgumentsAcceptOnlyIntegerAndDoubleValues`. Add
`import CoreLocation` to the top of the file if `CLLocationCoordinate2D`
members do not resolve. Five tests:

1. `testWholeNumberValueNeverTraps` — `.int(7)` → 7; `.double(7.0)` → 7;
   nil for `.double(7.5)`, `.double(1e300)`, `.double(.nan)`,
   `.double(.infinity)`, `.string("7")`, `.bool(true)`.
2. `testClampedIntArgument` — with `default: 30, in: 1 ... 100`: `[:]` → 30;
   `["limit": .null]` → 30; `.int(12)` → 12; `.double(40.0)` → 40;
   `.int(Int.max)` → 100; `.int(Int.min)` → 1; `.string("5")` and
   `.double(1e300)` and `.double(2.5)` each throw an error for which
   `error is ToolInputError` is true.
3. `testClampedNumberArgument` — with `default: 10, in: 1 ... 300`: `[:]` → 10;
   `.int(-5)` → 1; `.double(.infinity)` → 300; `.double(2.5)` → 2.5;
   `.double(.nan)` and `.string("2")` throw `ToolInputError`.
4. `testEnumArgumentRejectsUnknownNames` — using `ImageFormat` (cases `jpeg`,
   `png`): `[:]` with `default: ImageFormat.png` → `.png`;
   `["format": .string("jpeg")]` → `.jpeg`; `["format": .string("gif")]` throws
   and `sanitizedToolErrorMessage(for: error)` equals
   `"Invalid format. Expected one of: jpeg, png."`; `["format": .int(1)]` throws.
5. `testCoordinateArgumentRejectsPointsOffTheEarth` — `latitude 37.3,
   longitude -122.0` returns those values; custom keys
   (`latitude: "originLatitude", longitude: "originLongitude"`) work; throws for
   a missing longitude, latitude `91`, longitude `-181`, and latitude
   `.double(.nan)`.

Use `XCTAssertThrowsError(try ...) { error in XCTAssertTrue(error is ToolInputError) }`
as in `iMCPTests/ToolErrorSanitizationTests.swift:101-108`.

**Verify**:
```console
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh --only iMCPTests/ToolResultTests ; echo "exit=$?"
```
→ `exit=0` twice; the five new tests are listed as passed.

### Step 2: Cap `FetchPolicy.parseLimit` and make a wrong-typed `limit` an error

In `App/Models/FetchPolicy.swift:75-88`, add `throws` to `parseLimit` and
replace the `let requested = ...` line with:

```swift
        let requested = try clampedIntArgument(arguments, "limit", default: defaultLimit, in: 0 ... hardCap)
```

Add `try` at the four callers:

- `FetchPolicy.swift:124` → `let (requestedLimit, fetchLimit) = try parseLimit(`
- `App/Services/Calendar.swift:101-103` → make `calendarEventsFetchLimit`
  `throws` and its body `try FetchPolicy.parseLimit(from: arguments, defaultLimit: 500).fetch`;
  at `Calendar.swift:257` → `let limit = try calendarEventsFetchLimit(from: arguments)`
- `App/Services/ScreenTime.swift:89` and `:161` →
  `let limit = try FetchPolicy.parseLimit(from: arguments, defaultLimit: defaultLimit).requested`

Advertise the ceiling. In each `"limit": .integer(` schema entry below, add
`minimum: 0` (if absent) and `maximum: 500` after the `default:` argument
(argument order is `description`, `default`, `minimum`, `maximum`; see
`App/Services/Weather.swift:74-79`):

- `App/Services/Messages.swift:80-83`
- `App/Services/CallHistory.swift:69-72`
- `App/Services/ScreenTime.swift:64-68` and `:144-147`
- `App/Services/Location.swift:485-488`
- `App/Services/BrowserHistory.swift:123-126`
- `App/Services/Notifications.swift:416-419`
- `App/Services/Calendar.swift:186-190` (already has `minimum: 0`)

Tests, in `iMCPTests/AppModelTests.swift`:

- `testCalendarEventsFetchLimitCapsAt500` (line 386): mark it `throws` and
  prefix each `calendarEventsFetchLimit(` call with `try`.
- Add next to `testFetchPolicyWidensLimitWhenSearching` (line 276):
  `testFetchPolicyCapsRequestedLimit` asserting
  `try FetchPolicy.parse(from: ["limit": .int(Int.max)]).requestedLimit == 500`,
  `.int(-4)` → `0`, `.double(25.0)` → `25`, and that
  `["limit": .string("25")]` throws.

**Verify**:
```console
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
grep -c 'intValue' App/Models/FetchPolicy.swift
Scripts/test.sh --only iMCPTests/ServiceFixesTests ; echo "exit=$?"
```
→ `exit=0`, `0`, `exit=0`. (If the two FetchPolicy tests live in a different
class in your checkout, run `Scripts/test.sh --app-only` instead.)

### Step 3: Weather — delete `clampedIntArg`, validate coordinates

In `App/Services/Weather.swift`:

- Delete `clampedIntArg` (`:24-37`).
- Replace the three calls (`:91`, `:125`, `:160-165`) with
  `try clampedIntArgument(arguments, "days", default: 7, in: 1 ... 10)`,
  `try clampedIntArgument(arguments, "hours", default: 24, in: 1 ... 240)`,
  `try clampedIntArgument(arguments, "minutes", default: 60, in: 1 ... 120)`.
- Replace the body of `coordinates(from:)` (`:14-22`) with:

```swift
        let coordinate = try coordinateArgument(arguments)
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
```

If the file-level `log` constant (`:7`) is now unused and the build reports it,
delete that line and the `import OSLog` it needed.

**Verify**:
```console
grep -c 'clampedIntArg(' App/Services/Weather.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ `0`, `exit=0`.

### Step 4: Replace the hand-rolled limits

Each becomes one line; delete the lines it replaces.

| Site | Replace with | Schema change |
|------|--------------|---------------|
| `App/Services/Reminders.swift:111` | `let limit = try clampedIntArgument(arguments, "limit", default: 100, in: 0 ... 500)` | `:75-79` add `maximum: 500` |
| `App/Services/Notes.swift:154` | `let limit = try clampedIntArgument(arguments, "limit", default: defaultLimit, in: 1 ... 500)` | `:139-142` add `minimum: 1, maximum: 500` |
| `App/Services/Contacts.swift:230-233` | `let limit = try clampedIntArgument(arguments, "limit", default: 20, in: 1 ... 100)` | none (already `1...100`) |
| `App/Services/Photos.swift:350-355` | `let maxDimension = try clampedIntArgument(arguments, "maxDimension", default: 2048, in: 1 ... 2048)` | `:328-333` add `maximum: 2048` |
| `App/Services/Maps.swift:324` | `let limit = try clampedIntArgument(arguments, "limit", default: defaultSearchLimit, in: 1 ... 50)` | `:302-305` add `minimum: 1, maximum: 50` |

(`Photos.swift:219-222` and the `Maps.swift:516-517` width/height are handled
in Steps 9 and 8.)

**Verify**:
```console
git grep -n '"limit"\]?.intValue\|= arguments\["limit"\]' -- App/Services | grep -v Photos.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ no output from the grep, then `exit=0`.

### Step 5: Capture — bounded numbers, checked identifiers, one-line enums

In `App/Services/Capture.swift`:

1. Near the top (beside `cameraCaptureTimeout`, `:10-13`) add:

```swift
private let maxCaptureDimension = 4096

/// Display and window identifiers are `UInt32`. Converting an arbitrary
/// client integer with `UInt32(_:)` traps, so this is the only conversion.
func captureIdentifier(_ value: Value?, name: String) throws -> UInt32? {
    guard let value, value != .null else { return nil }
    guard let identifier = value.wholeNumberValue.flatMap({ UInt32(exactly: $0) }) else {
        throw ToolInputError("\(name) must be a whole number between 0 and \(UInt32.max)")
    }
    return identifier
}
```

2. `capture_record_audio`, replace `:317-327` with:

```swift
            let format = try enumArgument(arguments, "format", default: AudioFormat.default)
            let duration = try clampedNumberArgument(arguments, "duration", default: 10, in: 1 ... 300)
            let quality = try enumArgument(arguments, "quality", default: AudioQuality.default)
```

3. `capture_take_screenshot`, replace `:440-463` with:

```swift
            let contentType = try enumArgument(
                arguments,
                "contentType",
                default: ScreenCaptureContentType.default
            )
            let format = try enumArgument(arguments, "format", default: ImageFormat.png)
            let quality = try enumArgument(arguments, "quality", default: ScreenCaptureQuality.default)
            let includesCursor = arguments["includesCursor"]?.boolValue ?? true
            let maxDimension = try clampedIntArgument(
                arguments,
                "maxDimension",
                default: 2048,
                in: 1 ... maxCaptureDimension
            )
            let displayId = try captureIdentifier(arguments["displayId"], name: "displayId")
            let windowId = try captureIdentifier(arguments["windowId"], name: "windowId")
```

   Leave `let bundleId = ...` (`:464`) and everything after it unchanged.

4. `capturePicture(arguments:)`, replace `:647-678` with (keep
   `try await requestPermission(for: .video)` above it):

```swift
        let format = try enumArgument(arguments, "format", default: ImageFormat.default)
        let quality = try clampedNumberArgument(arguments, "quality", default: 0.8, in: 0 ... 1)
        let preset = try enumArgument(arguments, "preset", default: SessionPreset.default)
        let device = try enumArgument(arguments, "device", default: CaptureDeviceType.default)
        let position = try enumArgument(arguments, "position", default: CaptureDevicePosition.default)
        let flash = try enumArgument(arguments, "flash", default: FlashMode.default)
        let autoExposure = arguments["autoExposure"]?.boolValue ?? true
        let autoFocus = arguments["autoFocus"]?.boolValue ?? true
        let autoWhiteBalance = arguments["autoWhiteBalance"]?.boolValue ?? true
        let delay = try clampedNumberArgument(arguments, "delay", default: 1, in: 0 ... 60)
        let maxDimension = try clampedIntArgument(
            arguments,
            "maxDimension",
            default: 2048,
            in: 1 ... maxCaptureDimension
        )
```

5. Schemas: `:263-268` and `:421-426` add `maximum: maxCaptureDimension` after
   `minimum: 1`. Change `"displayId": .number(` (`:404`) and
   `"windowId": .number(` (`:409`) to `.integer(` (keep `description` and
   `minimum: 0`).

6. Tests, in `iMCPTests/AppModelTests.swift` inside
   `CaptureDimensionAndTimeoutTests` (line 44): `testCaptureIdentifierNeverTraps`
   — `nil` → nil; `.int(7)` → 7; `.double(7.0)` → 7; `.int(-1)`,
   `.int(5_000_000_000)`, `.double(1.5)`, `.string("7")` each throw
   `ToolInputError`.

**Verify**:
```console
grep -c 'CGDirectDisplayID(\$0)\|CGWindowID(\$0)\|(rawValue: arguments\[' App/Services/Capture.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh --only iMCPTests/CaptureDimensionAndTimeoutTests ; echo "exit=$?"
```
→ `0`, `exit=0`, `exit=0`.

### Step 6: EventKit — alarm offsets, due date, list names

In `App/Services/Reminders.swift`, next to `requireSingleCalendar` (`:254-271`),
add two file-scope helpers:

```swift
/// 366 days. An alarm further out than that is a mistake, and the bound keeps
/// `minutes * 60` inside `Int`.
private let maxAlarmMinutes = 527_040

/// Seconds relative to the due or start date for an alarm `minutes` argument:
/// positive minutes fire before it, negative after.
func alarmRelativeOffset(minutes value: Value) throws -> TimeInterval {
    guard let minutes = value.wholeNumberValue,
        (-maxAlarmMinutes ... maxAlarmMinutes).contains(minutes)
    else {
        throw ToolInputError(
            "Alarm minutes must be a whole number between -\(maxAlarmMinutes) and \(maxAlarmMinutes)"
        )
    }
    return TimeInterval(-minutes * 60)
}

/// Narrows `items` to the names the caller asked for; no names means all of
/// them. A name that matches nothing throws: EventKit does not document what
/// an empty calendars array selects, so a typo must not reach it.
func itemsMatchingRequestedNames<Item>(
    _ items: [Item],
    names: Value?,
    title: (Item) -> String,
    kind: String,
    listTool: String
) throws -> [Item] {
    guard case .array(let values) = names, !values.isEmpty else { return items }
    var requested: Set<String> = []
    for value in values {
        let name = value.stringValue ?? ""
        guard items.contains(where: { title($0).lowercased() == name.lowercased() }) else {
            throw ToolInputError("\(kind) not found: \(name). Call \(listTool) for valid names.")
        }
        requested.insert(name.lowercased())
    }
    return items.filter { requested.contains(title($0).lowercased()) }
}
```

Then:

- `Reminders.swift:91-101` → one statement (note `let`, not `var`):

```swift
            let reminderLists = try itemsMatchingRequestedNames(
                self.eventStore.calendars(for: .reminder),
                names: arguments["lists"],
                title: \.title,
                kind: "Reminder list",
                listTool: "reminders_lists"
            )
```

- `App/Services/Calendar.swift:202-208` → the same with
  `let calendars = try itemsMatchingRequestedNames(self.eventStore.calendars(for: .event), names: arguments["calendars"], title: \.title, kind: "Calendar", listTool: "calendars_list")`
  (wrap to 120 columns).
- `Reminders.swift:205-209`: replace the `if case .string(let dueDateStr) ... {`
  header (five lines) with the header below; leave the block body
  (`:210-218`) unchanged:

```swift
            if let parsedDueDate = try FetchPolicy.parseRawDate(
                try FetchPolicy.dateString(from: arguments, primary: "due")
            ) {
```

- `Reminders.swift:229-234`: replace the `compactMap` closure so the block reads:

```swift
            if case .array(let alarmMinutes) = arguments["alarms"] {
                reminder.alarms = try alarmMinutes.map {
                    EKAlarm(relativeOffset: try alarmRelativeOffset(minutes: $0))
                }
            }
```

- `Calendar.swift:470-472`: replace the three lines with:

```swift
                        if let minutes = config["minutes"] {
                            alarm = EKAlarm(relativeOffset: try alarmRelativeOffset(minutes: minutes))
                        }
```

Tests, in `iMCPTests/ToolErrorSanitizationTests.swift` inside
`ClientFacingToolErrorTests` (line 169), modelled on
`testUnknownCalendarNameReachesTheCaller`:

1. `testAlarmOffsetIsBoundedInsteadOfOverflowing` —
   `try alarmRelativeOffset(minutes: .int(15)) == -900`;
   `.int(-10)` → `600`; `.double(5.0)` → `-300`; `.int(Int.max)`,
   `.int(Int.min)`, `.string("15")` each throw `ToolInputError`.
2. `testRequestedNamesNarrowCaseInsensitively` —
   `try itemsMatchingRequestedNames(["Work", "Home"], names: .array([.string("work")]), title: { $0 }, kind: "Calendar", listTool: "calendars_list") == ["Work"]`;
   `names: nil` and `names: .array([])` both return `["Work", "Home"]`.
3. `testUnknownRequestedNameReachesTheCaller` — `names: .array([.string("Wrok")])`
   throws and `sanitizedToolErrorMessage(for: error)` equals
   `"Calendar not found: Wrok. Call calendars_list for valid names."`.

**Verify**:
```console
git grep -n 'minutes \* 60' -- App/Services/Calendar.swift App/Services/Reminders.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh --only iMCPTests/ClientFacingToolErrorTests ; echo "exit=$?"
```
→ exactly one grep hit (inside `alarmRelativeOffset`), `exit=0`, `exit=0`.

### Step 7: Location — three overflow sites

In `App/Services/Location.swift` change only these lines. 10 080 minutes is one week.

```swift
// :500
            let interval = try clampedIntArgument(arguments, "intervalMinutes", default: 0, in: 0 ... 10_080) * 60
// :579 and :663 (identical)
            let dwell = TimeInterval(
                try clampedIntArgument(arguments, "minimumMinutes", default: 10, in: 0 ... 10_080) * 60
            )
```

`interval` changes from `Int?` to `Int`. That is safe: the only consumer treats
0 and nil alike (`App/Services/Location/LocationHistoryStore.swift`,
`if let interval, interval > 0 {`).

**Verify**:
```console
grep -c 'intValue' App/Services/Location.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ `0`, `exit=0`.

### Step 8: Maps — enums, coordinates, distances

In `App/Services/Maps.swift`:

1. Replace `isValidMapImageDimension`, `mapsMapType`, and `mapsTransportType`
   (`:16-51`) with:

```swift
private let maxSearchRadius: CLLocationDistance = 100_000

enum MapsMapStyle: String, CaseIterable {
    case standard, satellite, hybrid, mutedStandard

    var mapType: MKMapType {
        switch self {
        case .standard: return .standard
        case .satellite: return .satellite
        case .hybrid: return .hybrid
        case .mutedStandard: return .mutedStandard
        }
    }
}

enum MapsTransportMode: String, CaseIterable {
    case automobile, walking, transit, cycling, any

    var transportType: MKDirectionsTransportType {
        switch self {
        case .automobile: return .automobile
        case .walking: return .walking
        case .transit: return .transit
        case .cycling: return .cycling
        case .any: return .any
        }
    }
}
```

2. Schemas: the two `enum: ["automobile", "walking", "transit", "cycling", "any"]`
   literals (`:214`, `:378`) become
   `enum: MapsTransportMode.allCases.map { .string($0.rawValue) }`; the
   `enum: ["standard", "satellite", "hybrid", "mutedStandard"]` literal (`:472`)
   becomes `enum: MapsMapStyle.allCases.map { .string($0.rawValue) }`.

3. **maps_search** (`:137-149`), replace the `if let regionArg ... { ... }` block:

```swift
            if let regionArg = arguments["region"]?.objectValue {
                let radius = try clampedNumberArgument(
                    regionArg,
                    "radius",
                    default: defaultSearchRadius,
                    in: 1 ... maxSearchRadius
                )
                searchRequest.region = MKCoordinateRegion(
                    center: try coordinateArgument(regionArg),
                    latitudinalMeters: radius,
                    longitudinalMeters: radius
                )
            }
```

4. **maps_directions** (`:224-261`): as the first statement of the handler add

```swift
            let transportMode = try enumArgument(arguments, "transportType", default: MapsTransportMode.automobile)
```

   Simplify the two guards (`:225-242`) to test only for presence —
   `arguments["originAddress"]?.stringValue != nil || arguments["originCoordinates"]?.objectValue != nil`
   and the same for `destination` — keeping both error messages. Replace
   `:257-261` with:

```swift
            let requestedMode = transportMode.rawValue
            directionsRequest.transportType = transportMode.transportType
```

5. **`getMapItem`** (`:820-828`), replace the `if let coordinates, let lat ..., let lng ... { ... }` block:

```swift
        if let coordinates {
            return MKMapItem(placemark: MKPlacemark(coordinate: try coordinateArgument(coordinates)))
        }
```

6. **maps_explore** (`:316-333`), replace the guard, `radius`, and the request's
   `center:` so it reads (the `limit` line is from Step 4; keep the category
   guard at `:326-328`):

```swift
            guard let categoryString = arguments["category"]?.stringValue else {
                throw ToolInputError("Category is required")
            }
            let center = try coordinateArgument(arguments)
            let radius = try clampedNumberArgument(
                arguments,
                "radius",
                default: defaultSearchRadius,
                in: 1 ... maxSearchRadius
            )
```

   and `MKLocalPointsOfInterestRequest(center: center, radius: radius)`.

7. **maps_eta** (`:393-418`), replace the guard and the two placemarks with:

```swift
            let transportMode = try enumArgument(arguments, "transportType", default: MapsTransportMode.automobile)
            let originPlacemark = MKPlacemark(
                coordinate: try coordinateArgument(
                    arguments,
                    latitude: "originLatitude",
                    longitude: "originLongitude"
                )
            )
            let destPlacemark = MKPlacemark(
                coordinate: try coordinateArgument(
                    arguments,
                    latitude: "destinationLatitude",
                    longitude: "destinationLongitude"
                )
            )
```

   and `:414-418` with the same two lines as in item 4
   (`let requestedMode = transportMode.rawValue` /
   `directionsRequest.transportType = transportMode.transportType`).

8. **maps_generate** (`:508-535`), replace from the opening guard through
   `options.mapType = mapType` with:

```swift
            let center = try coordinateArgument(arguments)
            guard let latitudeDelta = arguments["latitudeDelta"]?.numberValue,
                let longitudeDelta = arguments["longitudeDelta"]?.numberValue,
                latitudeDelta > 0, latitudeDelta <= 180,
                longitudeDelta > 0, longitudeDelta <= 360
            else {
                throw ToolInputError(
                    "latitudeDelta must be greater than 0 and at most 180; longitudeDelta greater than 0 and at most 360"
                )
            }
            let dimensions = minMapImageDimension ... maxMapImageDimension
            let width = try clampedIntArgument(
                arguments,
                "width",
                default: Int(defaultMapImageSize.width),
                in: dimensions
            )
            let height = try clampedIntArgument(
                arguments,
                "height",
                default: Int(defaultMapImageSize.height),
                in: dimensions
            )

            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
            )
            options.mapType = try enumArgument(arguments, "mapType", default: MapsMapStyle.standard).mapType
```

   (`NaN > 0` is false, so the guard also rejects non-finite deltas.) Leave the
   `let scale = NSScreen.main...` block (`:538-542`) untouched.

9. POI filter (`:550-554`), replace the `case let .array(poiTypes):` body:

```swift
            case let .array(poiTypes):
                let categories = try poiTypes.map { value -> MKPointOfInterestCategory in
                    guard let category = value.stringValue.flatMap({ MKPointOfInterestCategory.from(string: $0) })
                    else {
                        throw ToolInputError("Invalid POI category")
                    }
                    return category
                }
                filter = categories.isEmpty ? .excludingAll : .init(including: categories)
```

10. **maps_reverse_geocode** (`:653-660`), replace the guard and the call:

```swift
            let coordinate = try coordinateArgument(arguments)
            return try await self.reverseGeocode(latitude: coordinate.latitude, longitude: coordinate.longitude)
```

Tests:

- `iMCPTests/AppModelTests.swift:224-229`: delete `testMapImageDimensionBounds`
  (the function it tests is gone; the range is now covered by
  `testClampedIntArgument`).
- `iMCPTests/PhotoServiceTests.swift:48-59`: replace the two
  `mapsTransportType` tests with:

```swift
    func testTransportModeMapsEveryDeclaredMode() {
        XCTAssertEqual(MapsTransportMode.automobile.transportType, .automobile)
        XCTAssertEqual(MapsTransportMode.walking.transportType, .walking)
        XCTAssertEqual(MapsTransportMode.transit.transportType, .transit)
        XCTAssertEqual(MapsTransportMode.cycling.transportType, .cycling)
        XCTAssertEqual(MapsTransportMode.any.transportType, .any)
    }

    func testUnknownTransportModeIsRejectedNotRoutedByCar() throws {
        XCTAssertEqual(
            try enumArgument([:], "transportType", default: MapsTransportMode.automobile),
            .automobile
        )
        XCTAssertThrowsError(
            try enumArgument(
                ["transportType": .string("bicycle")],
                "transportType",
                default: MapsTransportMode.automobile
            )
        ) { error in
            XCTAssertTrue(error is ToolInputError)
        }
    }
```

**Verify**:
```console
git grep -n 'mapsMapType\|mapsTransportType\|isValidMapImageDimension' -- App iMCPTests
grep -c 'numberValue' App/Services/Maps.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh --only iMCPTests/PhotoServiceTests ; echo "exit=$?"
```
→ no grep output; `2` (the two delta reads in maps_generate); `exit=0`; `exit=0`.

### Step 9: Photos and Screen Time — dates, limit, enums; pin the schemas

`App/Services/Photos.swift`:

- Add at file scope: `private enum PhotoMediaFilter: String, CaseIterable { case image, video, any }`
- Replace `:190-199` with:

```swift
            let policy = try FetchPolicy.parse(from: arguments, defaultLimit: 30, hardCap: 100)
            if let startDate = policy.start {
                predicates.append(NSPredicate(format: "creationDate >= %@", startDate as NSDate))
            }
            if let endDate = policy.end {
                predicates.append(NSPredicate(format: "creationDate <= %@", endDate as NSDate))
            }
```

- Replace `:201-213` with a switch over the enum, keeping the two
  `predicates.append` bodies exactly as they are:

```swift
            switch try enumArgument(arguments, "mediaType", default: PhotoMediaFilter.any) {
            case .image:
                // existing image predicate
            case .video:
                // existing video predicate
            case .any:
                break
            }
```

- Delete `:219-222` (`var limit = 30` … `}`) and change `:225` to
  `fetchOptions.fetchLimit = max(policy.requestedLimit, 1)`. (PhotoKit reads a
  fetch limit of 0 as "no limit", hence the floor of 1.) If `limit` is used
  again further down the handler, replace those uses with the same expression
  bound to a `let limit`.
- Schema `:160-164`: add `maximum: 100` after `minimum: 1`.

`App/Services/ScreenTime.swift`:

- Add at file scope: `private enum UsageGrouping: String, CaseIterable { case app, day }`
- `:90` → `let groupBy = try enumArgument(arguments, "groupBy", default: UsageGrouping.app)`
- `:95` → `if groupBy == .day {`

Schema test, in `iMCPTests/CallToolDispatchTests.swift` inside
`ToolSchemaHygieneTests`, after `testNoDateBoundIsDocumentedTwice`:

```swift
    /// The server clamps every `limit`; a schema that hides the ceiling makes
    /// a client believe it received everything it asked for.
    func testEveryLimitAdvertisesItsCeiling() throws {
        for (name, properties) in try inputSchemas() {
            guard let limit = properties["limit"]?.objectValue else { continue }
            XCTAssertNotNil(limit["maximum"], "\(name).limit has no maximum")
        }
    }
```

**Verify**:
```console
grep -c 'arguments\["startDate"\]\|arguments\["mediaType"\]' App/Services/Photos.swift
grep -c 'groupBy == "day"' App/Services/ScreenTime.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh --only iMCPTests/ToolSchemaHygieneTests ; echo "exit=$?"
```
→ `0`, `0`, `exit=0`, `exit=0`.

### Step 10: Full gate

```console
swift format -i -r .
swift format lint --strict --recursive . ; echo "exit=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh ; echo "exit=$?"
git status --short
```

**Verify**: three `exit=0`; `git status --short` lists only files from the
in-scope list.

## Test plan

New tests, all in existing files (no `project.pbxproj` edit):

| File / class | Tests | Step |
|--------------|-------|------|
| `iMCPTests/AppModelTests.swift` / `ToolResultTests` | `testWholeNumberValueNeverTraps`, `testClampedIntArgument`, `testClampedNumberArgument`, `testEnumArgumentRejectsUnknownNames`, `testCoordinateArgumentRejectsPointsOffTheEarth` | 1 |
| `iMCPTests/AppModelTests.swift` (beside the other FetchPolicy tests) | `testFetchPolicyCapsRequestedLimit` | 2 |
| `iMCPTests/AppModelTests.swift` / `CaptureDimensionAndTimeoutTests` | `testCaptureIdentifierNeverTraps` | 5 |
| `iMCPTests/ToolErrorSanitizationTests.swift` / `ClientFacingToolErrorTests` | `testAlarmOffsetIsBoundedInsteadOfOverflowing`, `testRequestedNamesNarrowCaseInsensitively`, `testUnknownRequestedNameReachesTheCaller` | 6 |
| `iMCPTests/PhotoServiceTests.swift` | `testTransportModeMapsEveryDeclaredMode`, `testUnknownTransportModeIsRejectedNotRoutedByCar` (replace two) | 8 |
| `iMCPTests/CallToolDispatchTests.swift` / `ToolSchemaHygieneTests` | `testEveryLimitAdvertisesItsCeiling` | 9 |

Edited: `testCalendarEventsFetchLimitCapsAt500` (add `try`). Deleted:
`testMapImageDimensionBounds`.

Structural patterns: `ToolResultTests.testNumericArgumentsAcceptOnlyIntegerAndDoubleValues`
for value tests; `ClientFacingToolErrorTests.testUnknownCalendarNameReachesTheCaller`
for "throws and the message reaches the caller"; `ToolSchemaHygieneTests` for
registry-wide schema checks.

Not covered by automated tests (the handlers need live EventKit, PhotoKit,
MapKit, camera, or microphone): that each handler calls the helper. The grep
checks in each step's Verify are the gate for that.

Verification: `Scripts/test.sh` → exit 0, with 13 new tests (12 added, 2
replaced in place, 1 deleted).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `Scripts/test.sh` exits 0
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `git grep -n 'clampedIntArg(\|mapsMapType\|mapsTransportType\|isValidMapImageDimension' -- App iMCPTests` returns no matches
- [ ] `git grep -n 'minutes \* 60' -- App/Services` returns exactly one match, in `App/Services/Reminders.swift` inside `alarmRelativeOffset`
- [ ] `git grep -n 'CGDirectDisplayID(\$0)\|CGWindowID(\$0)' -- App` returns no matches
- [ ] `git grep -n 'arguments\["limit"\]' -- App` returns no matches
- [ ] `git grep -c 'func clampedIntArgument\|func clampedNumberArgument\|func enumArgument\|func coordinateArgument' -- App/Models/Value+Number.swift` prints `App/Models/Value+Number.swift:4`
- [ ] `git grep -n 'testEveryLimitAdvertisesItsCeiling' -- iMCPTests` returns one match
- [ ] `git diff --stat main -- iMCP.xcodeproj Scripts CLI App/Views` prints nothing
- [ ] `git status --short` shows no files outside the in-scope list
- [ ] `plans/README.md` status row for 038 updated

## STOP conditions

Stop and report back (do not improvise) if:

- The drift check shows changes in an in-scope file and the excerpts in
  "Current state" no longer match — in particular if plan 040 or plan 049 has
  already landed in `Location.swift`, `Maps.swift`, or `Photos.swift` (they are
  meant to apply **after** this plan).
- Plan 037 is not merged: `Scripts/test.sh` results are not trustworthy until
  it is.
- `enumArgument` does not compile as written (for example the generic
  constraint is rejected, or a call site cannot infer `Choice`). Report the
  compiler message; do not swap in per-site `switch` statements.
- `case nil, .string(...)` or `value != .null` does not compile against the MCP
  SDK's `Value` (the SDK version changed).
- An existing test other than the three named in "Tests that pin today's
  behaviour" fails. That means some caller depended on a silent fallback this
  plan removes; report which test and which argument.
- `testEveryLimitAdvertisesItsCeiling` fails for a tool not listed in Steps 2,
  4, or 9 — a new tool with a `limit` appeared; report it.
- Any step seems to need a new file, a `project.pbxproj` edit, or a change to a
  file outside the in-scope list.
- A step's verification fails twice after a reasonable fix attempt.
- You are tempted to run `xcodebuild test -scheme iMCP` directly, or to stop
  the always-on agent with `launchctl`. Don't; use `Scripts/test.sh`.

## Maintenance notes

For the human/agent who owns this code after the change lands:

- **Behaviour changes a reviewer should confirm are wanted.** (1) A `limit`,
  `days`, `maxDimension`, etc. sent as a string or a fractional number now
  errors instead of using the default; `40.0` is now accepted where it used to
  be ignored. (2) `maps_generate` `width`/`height` outside 128...2048 are now
  clamped instead of rejected. (3) Unknown enum values, unknown calendar or
  list names, an unparseable `due`, and off-Earth coordinates now error.
  (4) `messages_fetch`, `calls_fetch`, and the two Screen Time tools now return
  at most 500 rows per call; `maps_explore` at most 50; `notes_search` and
  `reminders_fetch` at most 500. (5) Capture `maxDimension` is capped at 4096.
- **New tools**: parse every numeric argument with `clampedIntArgument` /
  `clampedNumberArgument`, every enum with `enumArgument`, every lat/lon pair
  with `coordinateArgument`. Never call `Int(_:)` on a client `Double` or do
  arithmetic on a client `Int` before bounding it.
- **Deferred, same class, deliberately not done here** (each is a silent
  fallback on an enum-like string; fix with `enumArgument` in a follow-up):
  `App/Services/CallHistory.swift:92-100` (`direction`),
  `App/Services/BrowserHistory.swift:147-155` (`browser`),
  `App/Services/Calendar.swift:239-247` and `:455-457` (`status`,
  `availability`), `App/Services/Reminders.swift:225-227` (`priority`,
  `EKReminderPriority.from(string:)` defaults to `.none`), and the Calendar
  alarm loop's skipped entries (`Calendar.swift:474-517`).
- **Plan 040** edits `Location.swift:497-526` and adds validation to
  `location_place_set`; it should reuse `coordinateArgument` and
  `clampedNumberArgument` for latitude/longitude/`radiusMeters`.
- **Plan 049** rewrites the MapKit continuation blocks and fixes the
  radius-as-diameter bug at the `maps_search` region; the `radius` it doubles is
  now the clamped value from Step 8.
- **Plan 042** owns error-type consolidation; the helpers here throw
  `ToolInputError` and `FetchPolicy.Error` only.
- **Schema bytes**: this plan adds about fifteen `maximum:` keys and removes
  three literal enum arrays. `ToolSchemaHygieneTests` now fails if a `limit`
  lacks a `maximum`.
- **Do not install** (`Scripts/install-local.sh run`) as part of this plan
  unless the operator asks.
