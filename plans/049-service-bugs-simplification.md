# Plan 049: Fix service bugs by deleting and consolidating service code

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- App/Services/Maps.swift App/Services/Photos.swift App/Services/ScreenTime.swift App/Services/CallHistory.swift App/Services/Notifications.swift App/Services/BrowserHistory.swift App/Services/Messages.swift App/Services/Shortcuts.swift App/Services/Notes.swift App/Services/Capture.swift App/Services/RemoteNotificationsStore.swift App/Services/BookmarkedSQLiteStore.swift App/Services/Location/LocationHistoryStore.swift App/Extensions/AppKit+Extensions.swift App/Extensions/Foundation+Extensions.swift App/Extensions/Logger+Extensions.swift iMCPTests`
> Drift is **expected** in these files, because plans 038 and 042 land first
> and edit argument parsing and error types in them. Every step below names
> the symbol to change, not only a line number. Find the symbol; if the symbol
> itself is gone or its logic differs from the excerpt (not just its argument
> parsing or the error type it throws), treat that as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: L (nine independent units; each is S or M on its own)
- **Risk**: MED — Unit E (Notes threading) and Unit I (Maps async rewrite) cannot be covered by unit tests and need a manual check by the operator
- **Depends on**: plans/038-validate-tool-arguments.md, plans/042-actionable-tool-errors.md
- **Category**: bug
- **Planned at**: commit `8165d29`, 2026-10-12

## Why this matters

Eleven service files carry real, user-visible defects that sit inside
duplicated or dead code. `maps_search` searches a quarter of the area the
caller asked for. Geocoding drops the house number. Screen Time
totals count whole sessions that only partly fall in the requested range. A
shortcut that writes a lot to stderr hangs for five minutes, and one that
writes non-UTF-8 output is reported as failed after it already ran. Every
Notes tool freezes the menu bar UI and stalls new connections while
AppleScript runs. iPhone notifications with no title show the literal text
`$null`.

The fix for most of these is to delete code: five hand-rolled MapKit
continuations, four copies of one SQLite loop, and four copies of one
open/close/security-scope handle. The plan should remove roughly 120 more
lines than it adds.

## How this plan is organised

Nine units, A to I. **Each unit is independent, ends with its own verify and
its own commit, and leaves the build green.** The one exception is Unit C,
which is a check with no edit and no commit (see Unit C). You may stop cleanly after any
unit and report which ones are done. Do them in order: G uses the type F
creates, and I uses the helpers H changes.

| Unit | Subject | Files |
|------|---------|-------|
| A | Dead code | `Logger+Extensions.swift`, `RemoteNotificationsStore.swift`, `Foundation+Extensions.swift` and callers, `Photos.swift` |
| B | `$null` in iPhone notifications | `RemoteNotificationsStore.swift` |
| C | Photos place-name lookup: keep it (check only, no edit) | none |
| D | Shortcuts stderr and output | `Shortcuts.swift` |
| E | Notes off the main thread | `Notes.swift` |
| F | One read-only SQLite handle | `BookmarkedSQLiteStore.swift` and five services |
| G | Screen Time | `ScreenTime.swift` |
| H | Image encoding | `AppKit+Extensions.swift`, `Capture.swift` |
| I | Maps | `Maps.swift`, `Foundation+Extensions.swift` |

## Current state

All excerpts are from commit `8165d29`. Paths are relative to the repo root
`~/Documents/GitHub/iMCP`.

### Repo facts you need

- macOS menu-bar MCP server. App code is in `App/`, app tests in `iMCPTests/`.
  Swift 6 strict concurrency, **warnings are errors**, deployment target
  macOS 15.1, not sandboxed.
- `App/` is a synchronized Xcode group: a new or deleted file under `App/`
  needs no project edit. **Test files are not**: each one has four hand-made
  entries in `iMCP.xcodeproj/project.pbxproj`. This plan creates **no** new
  test file and deletes none. Add tests to the existing files named below.
- A tool is declared as `Tool(name:description:inputSchema:annotations:) { arguments in ... }`
  (`App/Models/Tool.swift:11-56`). The closure is `@Sendable`, receives
  `[String: Value]` and returns `Value` or any `Encodable`.
- An error reaches the MCP client only if it conforms to `ClientFacingError`
  (`App/Controllers/ToolErrorResponse.swift`). Everything else is replaced by
  a generic message. Bad arguments throw `ToolInputError("...")`.
- Local Xcode is 27 beta, CI is Xcode 26. Xcode 27 fails the build on two
  extra diagnostics: `ImplicitStrongCapture` (write `[self]` in the capture
  list of a `Task { }` when a strong capture is intended) and
  `NoUseUnstructuredThrowingTask` (do not create a `Task` whose body can throw
  unless you use its value; keep `Task` bodies non-throwing with `do/catch`
  or `try?`).
- `ResumeGate` (`App/Shared/ResumeGate.swift`) is an actor whose
  `shouldResume()` returns `true` exactly once. The repo uses it to make sure
  a continuation is resumed once.
- `Place` and `Trip` (package Ontology) are `Sendable` and have the
  initialisers `Place(_: MKMapItem)`, `Trip(_: MKDirections.Response)` and
  `Trip(_: MKDirections.ETAResponse)`. `Value` (package MCP) is `Sendable`.

### Unit A — dead code

`App/Extensions/Logger+Extensions.swift:13-15`, no callers anywhere:

```swift
    static func integration(_ name: String) -> Logger {
        Logger(subsystem: subsystem, category: "integrations.\(name)")
    }
```

`App/Services/RemoteNotificationsStore.swift:163-165`, no callers (app or tests):

```swift
    static func readLibraryArchive(below rootURL: URL, maximumBytes: Int = 8 * 1_024 * 1_024) throws -> Data {
        try readLibrarySnapshot(below: rootURL, maximumBytes: maximumBytes).data
    }
```

`App/Extensions/Foundation+Extensions.swift:119-125`:

```swift
/// Seconds between the Unix epoch (1970-01-01) and the Core Data
/// reference date (2001-01-01).
let coreDataReferenceOffset: TimeInterval = 978_307_200

func coreDataTimestamp(from date: Date) -> Double {
    date.timeIntervalSince1970 - coreDataReferenceOffset
}
```

`coreDataTimestamp(from:)` is exactly `date.timeIntervalSinceReferenceDate`.
It is called at `BrowserHistory.swift:46`, `CallHistory.swift:232,236`,
`Notifications.swift:133,137`, `ScreenTime.swift:377,378,439,440,496,497,547,548`,
and in tests at `iMCPTests/CallHistoryServiceTests.swift:11,16`,
`iMCPTests/NotificationsServiceTests.swift:480`,
`iMCPTests/ScreenTimeServiceTests.swift:19,76`. The constant
`coreDataReferenceOffset` is still used inside SQL text in `ScreenTime.swift`
and **stays**.

`App/Services/Photos.swift:92` — `NSObject` is not used (no `override`, no
`#selector`, no delegate conformance in the file):

```swift
final class PhotoService: NSObject, Service {
```

`App/Services/Photos.swift:29-32` re-clamps a value its only caller
(`photos_fetch_image`, `Photos.swift:350-355`) already bounded to `1 ... 2048`:

```swift
func photoFetchTargetSize(maxDimension: Int) -> CGSize {
    let dimension = CGFloat(max(maxDimension, 1))
    return CGSize(width: dimension, height: dimension)
}
```

Its only other use is the test `testFetchImageTargetSizeIsBoundedByMaxDimension`
(`iMCPTests/PhotoServiceTests.swift:13-18`).

### Unit B — `$null`

In an `NSKeyedArchiver` archive a nil object is a reference to object 0, the
string `$null`. The array reader knows this; the string and date readers do not.
`App/Services/RemoteNotificationsStore.swift:654-656` and `:685-690`:

```swift
    func array(_ value: BinaryPlistValue, maximumDepth: Int) throws -> [BinaryPlistValue] {
        let object = try dereference(value, depth: 0, maximumDepth: maximumDepth)
        if case .string("$null") = object { return [] }
```

```swift
    func string(_ value: BinaryPlistValue?, maximumDepth: Int) throws -> String? {
        guard let value else { return nil }
        let object = try dereference(value, depth: 0, maximumDepth: maximumDepth)
        guard case .string(let text) = object else { throw RemoteNotificationStoreError.malformed }
        return text
    }
```

So a notification archived with a nil title, subtitle or body
(`RemoteNotificationsStore.swift:128-133`) comes back with the literal text
`$null`, and a nil `AppNotificationIdentifier` is accepted as the identifier
`"$null"`. `date(_:maximumDepth:)` at `:692` has the same gap: a nil date
throws `malformed` from the wrong branch (harmless today because the caller
requires a date, but it is the same missing check).

### Unit C — Photos place-name lookup (kept)

`photos_search` (`App/Services/Photos.swift:144-274`) adds a `placeName` to
each result that has a location. At `:256` it does:

```swift
            let placeNames = await Self.lookupPlaceNames(for: assets)
```

`lookupPlaceNames` (`:458-509`) makes up to five serial `CLGeocoder` network
requests, each with a 2 s timeout, sending rounded photo coordinates to Apple.
The supporting code is: `maxGeocodeLookupsPerSearch` (`:11`), `geocodeTimeout`
(`:15`), `GeocodeTimeoutError` (`:17`), `photoPlaceCacheKey` (`:25-27`),
`PlaceNameCache` (`:54-90`), `placeNameCache` (`:427`), `lookupPlaceNames`
(`:458-509`), `reverseGeocodePlaceName` (`:511-548`), and the merge loop at
`:258-272`. Its tests are the class `PlaceNameCacheTests`
(`iMCPTests/PlaceNameCacheTests.swift:5-43`) and three `testPlaceCacheKey...`
tests in `iMCPTests/PhotoServiceTests.swift` (`:8-11`, `:66-70`, `:72-76`).

**All of this stays, unchanged.** An earlier draft of this plan deleted it.
The owner reversed that on 2026-10-12: `placeName` is a feature, and the only
defect was that the tool was annotated as local when it makes a network call.
Plan 039 fixes the annotation by marking `photos_search` open-world.

The Photos timeout code is separate from the Maps timeout code. `Photos.swift`
has its own file-private `geocodeTimeout` (2 s) and `GeocodeTimeoutError`, and
its own continuation in `reverseGeocodePlaceName`. `Maps.swift` has a
different file-private `geocodeTimeout` (10 s, `Maps.swift:14`) and
`withGeocodeTimeout` (`Maps.swift:725`). Nothing is shared between the two
files, so Unit I's changes to `Maps.swift` do not affect `Photos.swift`.

### Unit D — Shortcuts

`App/Services/Shortcuts.swift`. `listShortcuts` drains both pipes while the
child runs (`:125-136`):

```swift
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                outputBuffer.append(data)
            }
        }
        errorHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                errorBuffer.append(data)
            }
        }
```

`runShortcut` does not. It creates the pipe (`:249-252`) and reads it only
after the child has exited (`:281` and `:290-292`):

```swift
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let errorHandle = errorPipe.fileHandleForReading
        defer { errorHandle.closeFile() }
```

```swift
        if errorData.isEmpty {
            errorData = (try? errorHandle.readToEnd()) ?? Data()
        }
```

A pipe holds about 64 KB. A shortcut that writes more than that to stderr
blocks on the write, never exits, and is killed by the 5-minute timeout.

After a successful run (`:304-311`):

```swift
        let output: String?
        do {
            output = try String(contentsOf: outputFileURL, encoding: .utf8)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            output = nil
        }
```

Any other read error — most commonly output that is not valid UTF-8 — is
rethrown, so a shortcut that already ran (`destructiveHint: true`) is reported
as failed and the agent may run it again.

`PipeBuffer` (`:6-19`) is a private lock-protected `Data` accumulator.

### Unit E — Notes

`App/Services/Notes.swift:243-269`:

```swift
    /// Runs an AppleScript on the main thread (NSAppleScript is not
    /// thread-safe) and maps Automation-permission errors to a clear message.
    @MainActor
    private func runAppleScript(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw NotesError.scriptFailed("could not compile script")
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
```

`executeAndReturnError` is synchronous and can take seconds against a large
Notes library. On the main actor it freezes the menu bar UI. The network
listener also delivers on the main queue
(`App/Controllers/NetworkDiscoveryManager.swift:92` and `:119`,
`listener.start(queue: .main)`), so new MCP connections stall too. Callers are
`activate()` (`:53`) and the three tools (`:81`, `:150`, `:227`), all already
`try await self.runAppleScript(...)`.

### Unit F — SQLite handles

The same init/deinit pair appears three times verbatim, differing only in the
error it throws. `App/Services/ScreenTime.swift:329-354`:

```swift
    init(path: String, holdingAccessTo scopedURL: URL? = nil) throws {
        if let scopedURL {
            guard scopedURL.startAccessingSecurityScopedResource() else {
                throw BookmarkedSQLiteStore.AccessError.securityScopeAccessFailed
            }
        }
        self.scopedURL = scopedURL

        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let handle
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle {
                sqlite3_close(handle)
            }
            scopedURL?.stopAccessingSecurityScopedResource()
            throw DatabaseError.openFailed(message)
        }
        self.db = handle
    }

    deinit {
        sqlite3_close(db)
        scopedURL?.stopAccessingSecurityScopedResource()
    }
```

The other copies: `App/Services/CallHistory.swift:191-218`
(`CallHistoryDatabase`, throws `DatabaseAccessError.databaseOpenFailed`) and
`App/Services/Notifications.swift:82-115` (`NotificationsDatabase`, which on
failure classifies the path with `access(2)` into a
`NotificationSourceStatus`). A fourth, `App/Services/BrowserHistory.swift:223-254`
(`BrowserHistoryDatabase`), has no security scope and opens
`"file:\(browser.databasePath)?immutable=1"` with
`SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`.

`App/Services/Messages.swift:379-397` (`AttachmentReader`) also opens SQLite,
but with `SQLITE_OPEN_NOMUTEX`, a busy timeout, an explicit `close()`, and its
security scope held by the enclosing `withDatabaseConnection`. **It is not the
same shape and is not consolidated here.**

`SQLITE_TRANSIENT` is defined three times as a private global, identically:
`BrowserHistory.swift:8`, `Notifications.swift:13`,
`Location/LocationHistoryStore.swift:7`, and a fourth time as
`AttachmentReader.transient` (`Messages.swift:383`):

```swift
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
```

The home directory is hand-built five times as `"/Users/\(NSUserName())"`,
which is wrong for any account whose home is not under `/Users`:
`BrowserHistory.swift:20`, `CallHistory.swift:7`, `Messages.swift:7`,
`Notifications.swift:6`, `ScreenTime.swift:6`. The repo's own correct form is
`App/Models/FullDiskAccess.swift:14`: `let home = NSHomeDirectory()`.

`BookmarkedSQLiteStore.resolvedAccess()` (`App/Services/BookmarkedSQLiteStore.swift:113-119`)
returns `(path: String, scopedURL: URL?)`. It **stays as it is**: tests build
`CallHistoryService.CallHistoryDatabase(path:)` and
`LocalNotificationSource(databasePath:)` from a bare path
(`iMCPTests/CallHistoryServiceTests.swift:51`, `iMCPTests/NotificationsServiceTests.swift:110`).

### Unit G — Screen Time

`App/Services/ScreenTime.swift`.

Sessions are not clipped to the requested range. `fetchUsage` (`:356-369`):

```swift
            SELECT ZVALUESTRING AS bundle,
                   SUM(ZENDDATE - ZSTARTDATE) AS total,
                   COUNT(*) AS sessions
            FROM ZOBJECT
            WHERE ZSTREAMNAME = '/app/usage'
              AND ZVALUESTRING IS NOT NULL
              AND ZSTARTDATE >= ?
              AND ZSTARTDATE < ?
```

A session that starts before `endDate` and runs past it is counted in full; a
session that starts before `startDate` and runs into the range is not counted
at all. The same `WHERE` and `SUM` are in `fetchDailyUsage` (`:411-428`),
`fetchWebUsage` (`:473-487`) and `fetchDeviceActivity` (`:527-539`).

The four fetch functions each repeat the same prepare / bind / step loop
(`:371-407`, `:433-469`, `:490-523`, `:541-578`), feeding four private entry
structs (`:279-303`) that the tool closures immediately map back into `Value`
objects (`:99-116`, `:165-171`, `:219-226`).

The `startDate` / `endDate` schema is written out three times identically
(`:54-63`, `:134-143`, `:192-201`), and the result envelope three times
(`:118-124`, `:175-181`, `:229-235`):

```swift
            return [
                "@context": "https://schema.org",
                "@type": "ItemList",
                "startDate": .string(startDate.localISO8601),
                "endDate": .string(endDate.localISO8601),
                "itemListElement": Value.array(items),
            ]
```

`resolveRange` (`:239-270`) uses a helper and a three-way branch for what is
one expression:

```swift
func screenTimeDefaultRange(now: Date = Date()) -> Range<Date> {
    return now.addingTimeInterval(-defaultRangeDuration) ..< now
}
```

```swift
        let endDate = parsedEnd ?? defaultRange.upperBound
        var startDate: Date
        if let parsedStart {
            startDate = parsedStart
        } else if parsedEnd != nil {
            startDate = endDate.addingTimeInterval(-defaultRangeDuration)
        } else {
            startDate = defaultRange.lowerBound
        }
```

In the third branch `defaultRange.lowerBound` is `now - 7 days` and `endDate`
is `now`, so it equals the second branch. `screenTimeDefaultRange` has one
test, `testDefaultRangeSpansSevenDaysEndingNow`
(`iMCPTests/ScreenTimeServiceTests.swift:6-13`).

`KnowledgeDatabase` (`:277`) is `private final class`, so it has no test.

### Unit H — image encoding

`App/Extensions/AppKit+Extensions.swift:31-49`:

```swift
extension NSImage {
    var bitmap: NSBitmapImageRep? {
        guard let tiffData = tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiffData)
    }

    func pngData() -> Data? {
        return bitmap?.representation(using: .png, properties: [:])
    }

    func jpegData(compressionQuality: Double) -> Data? {
        return bitmap?.representation(
            using: .jpeg,
            properties: [
                .compressionFactor: compressionQuality
            ]
        )
    }
}
```

Every encode first serialises the whole image to an uncompressed TIFF
(16 MB for a 2048 x 2048 image) and parses it back. `CGImage` already has
direct encoders: `App/Extensions/CoreGraphics+Extensions.swift:6` (`pngData()`)
and `:25` (`jpegData(compressionQuality: CGFloat)`).

Callers of the `NSImage` versions: `Maps.swift:587`, `Capture.swift:871` and
`:888` (camera), `Photos.swift:396`. `bitmap` has no other caller.

`capture_take_screenshot` defaults to PNG while `capture_take_picture`
defaults to JPEG. `App/Services/Capture.swift:394-397` and `:445-448`:

```swift
                    "format": .string(
                        default: .string(ImageFormat.png.rawValue),
                        enum: ImageFormat.allCases.map { .string($0.rawValue) }
                    ),
```

```swift
            let format =
                ImageFormat(
                    rawValue: arguments["format"]?.stringValue ?? ImageFormat.png.rawValue
                ) ?? .png
```

`ImageFormat` (`App/Extensions/AVFoundation+Extensions.swift:94-108`) has
`static let default: ImageFormat = .jpeg`, cases `jpeg` and `png`, and
`mimeType`. A PNG screenshot is several times larger than a JPEG and every
byte is base64-encoded into the model's context.

### Unit I — Maps

`App/Services/Maps.swift`.

**Radius used as diameter.** The schema (`:112-113`) says
`"radius"` is "Search radius in meters". `maps_search` (`:141-147`):

```swift
                let radius = regionArg["radius"]?.numberValue ?? defaultSearchRadius
                let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                let region = MKCoordinateRegion(
                    center: center,
                    latitudinalMeters: radius,
                    longitudinalMeters: radius
                )
```

`latitudinalMeters` and `longitudinalMeters` are the full north-south and
east-west extent of the region, so this is a box `radius` metres across: half
the intended width, a quarter of the area. `maps_explore` (`:330-333`) passes
the same number to `MKLocalPointsOfInterestRequest(center:radius:)`, where it
really is a radius.

**House number dropped.** `placeValue` (`:776-778`), used by `maps_geocode`
and `maps_reverse_geocode`:

```swift
        if let thoroughfare = placemark.thoroughfare {
            addressComponents["streetAddress"] = .string(thoroughfare)
        }
```

`thoroughfare` is the street name only; the number is `subThoroughfare`,
which is never read.

**Five hand-rolled continuations**, each wrapping a MapKit call that has an
`async` form: `maps_search` (`:151-176`, `MKLocalSearch.start`),
`maps_directions` (`:263-284`, `MKDirections.calculate`), `maps_explore`
(`:336-361`, `MKLocalSearch.start`), `maps_eta` (`:420-441`,
`MKDirections.calculateETA`), `maps_generate` (`:562-606`,
`MKMapSnapshotter.start`). The file already uses the async form once
(`:804-805`):

```swift
            let search = MKLocalSearch(request: searchRequest)
            let response = try await search.start()
```

Three branches inside those continuations are unreachable, because MapKit
never calls back with neither a response nor an error: `NSError` code 2
(`:160-170`), code 8 (`:345-355`), code 14 (`:573-584`).

**No deadline.** None of those five calls has a timeout; a MapKit request
that never calls back hangs the tool call forever. Only the two geocode tools
have one, `withGeocodeTimeout` (`:725-752`), and it leaves a sleeping `Task`
alive for 10 s after every successful call:

```swift
            body(geocoder, finish)
            Task {
                try? await Task.sleep(for: .seconds(geocodeTimeout))
                geocoder.cancelGeocode()
                finish(
```

**Serial lookups.** `maps_directions` (`:244-252`) resolves the origin, waits,
then resolves the destination. Each is a network search.

**Screen-dependent image size.** `maps_generate` (`:538-542`):

```swift
            let scale = NSScreen.main?.backingScaleFactor ?? 1
            options.size = CGSize(
                width: CGFloat(width) / scale,
                height: CGFloat(height) / scale
            )
```

`NSScreen.main` is the screen with keyboard focus, read here off the main
thread. The pixel size of the result, and how large labels are drawn, depends
on which display happens to be focused. `maps_generate` also always encodes
PNG (`:587`, `:603`), which is large for satellite imagery.

`clampedCaptureImage(_:maxDimension:)` (`App/Services/Capture.swift:29-76`) is
an existing internal function that redraws an `NSImage` into a bitmap of exact
pixel dimensions when its largest side exceeds `maxDimension`, and returns the
image unchanged otherwise. It is tested by
`testClampedCaptureImageProducesExactPixelDimensions`
(`iMCPTests/AppModelTests.swift:79-95`).

`MapsError` (`:57-72`) is the file's `ClientFacingError`:

```swift
enum MapsError: Swift.Error, ClientFacingError, Equatable {
    case noRoute(mode: String)
    case routingUnavailable
```

`mapsRoutingError(from:mode:)` (`:79-89`) maps `MKError` codes to it and
**must keep being applied** to errors from `calculate()` and `calculateETA()`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| App tests | `Scripts/test.sh --app-only` | all pass |
| One test class | `Scripts/test.sh --only iMCPTests/<TestClass>` | all pass |
| All tests | `Scripts/test.sh` | all pass |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

- `-quiet` prints nothing on success; **success is exit code 0**.
- `--only SPEC` passes `-only-testing:SPEC` to the app suite and may be
  repeated.
- **Never run `xcodebuild test -scheme iMCP` directly.** A watchdog relaunches
  the installed app and breaks the test host; `Scripts/test.sh` handles that.
  **Never `launchctl bootout` the always-on agent.**
- If `xcodebuild` reports "failed with exit code 0 but produced no further
  output", run it again.

## Scope

**In scope** (the only files you should modify):

- `App/Extensions/AppKit+Extensions.swift`
- `App/Extensions/Foundation+Extensions.swift`
- `App/Extensions/Logger+Extensions.swift`
- `App/Services/BookmarkedSQLiteStore.swift`
- `App/Services/BrowserHistory.swift`
- `App/Services/CallHistory.swift`
- `App/Services/Capture.swift` (the screenshot `format` default only)
- `App/Services/Location/LocationHistoryStore.swift` (delete one line)
- `App/Services/Maps.swift`
- `App/Services/Messages.swift` (two one-line edits)
- `App/Services/Notes.swift`
- `App/Services/Notifications.swift`
- `App/Services/Photos.swift` (Unit A4 only)
- `App/Services/RemoteNotificationsStore.swift`
- `App/Services/ScreenTime.swift`
- `App/Services/Shortcuts.swift`
- `iMCPTests/AppModelTests.swift`
- `iMCPTests/CallHistoryServiceTests.swift`
- `iMCPTests/NotesServiceTests.swift` (hosts the new Shortcuts test class)
- `iMCPTests/NotificationsServiceTests.swift`
- `iMCPTests/PhotoServiceTests.swift`
- `iMCPTests/ScreenTimeServiceTests.swift`

**Out of scope** (do NOT touch, even though they look related):

- `iMCP.xcodeproj/project.pbxproj` — no file is added or removed.
- Do not remove or change the `photos_search` place-name lookup or its
  `placeName` output. Owner decision 2026-10-12: the feature stays; plan 039
  marks the tool open-world. This covers `lookupPlaceNames`,
  `reverseGeocodePlaceName`, `PlaceNameCache`, `GeocodeTimeoutError`,
  `photoPlaceCacheKey`, `maxGeocodeLookupsPerSearch`, the Photos
  `geocodeTimeout`, the `photos_search` description, and
  `iMCPTests/PlaceNameCacheTests.swift` (the whole file).
- Argument validation, ranges and the `maxDimension` cap — plan 038.
- Which errors are `ClientFacingError` and their wording — plan 042. The one
  exception is the single `MapsError.timedOut` case this plan adds.
- Tool annotations (`readOnlyHint` and so on) — plan 039.
- `README.md`, `docs/` — plan 053.
- `Messages.swift` `AttachmentReader` beyond the `transient` constant, and
  everything in the `iMessage`/Madrid package.
- `App/Services/Location/` other than the one deleted line — plans 040, 046, 047.
- The Screen Time device filter (`ZSOURCE`): the queries include usage synced
  from other devices. Do not change it; see Maintenance notes.
- `listShortcuts` behaviour, other than replacing its two handler blocks with
  the shared helper.
- `CLI/`, `AlwaysOnHelper/`, `Scripts/`.

## Git workflow

- Start from an up-to-date `main` that already contains plans 038 and 042.
- Branch: `advisor/049-service-bugs-simplification`
- One commit per unit (Unit C has none), conventional commits, matching the repo's style
  (e.g. `fix: bring Settings forward from the menu; stay quiet on relaunch`,
  `feat(messages): add conversations, attachments, and chatId to messages_fetch`).
  Suggested messages are given at the end of each unit.
- Do NOT push or open a PR unless the operator says so. This is a fork:
  `origin` (`cyberpapiii/iMCP`) is the only writable remote. `upstream`
  (`mattt/iMCP`) must never receive a push or a PR.

## Steps

### Step 0: Preconditions

1. Open `plans/README.md` and confirm plans 038 and 042 are `DONE`. If either
   is not, STOP and report, unless the operator has told you to proceed
   without them.
2. Run the drift check at the top of this file and read the note under it.
3. Create the branch.

**Verify**: `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"` → `exit=0`
and `Scripts/test.sh --app-only` → all pass. If the baseline is not green,
STOP.

---

### Unit A: Delete dead code

**A1.** In `App/Extensions/Logger+Extensions.swift` delete
`static func integration(_:)` (three lines plus the blank line before it).

**A2.** In `App/Services/RemoteNotificationsStore.swift` delete
`static func readLibraryArchive(below:maximumBytes:)`.

**A3.** In `App/Extensions/Foundation+Extensions.swift` delete
`func coreDataTimestamp(from:)`. Keep `coreDataReferenceOffset` and its
comment. Replace every call `coreDataTimestamp(from: X)` with
`X.timeIntervalSinceReferenceDate` in `BrowserHistory.swift`,
`CallHistory.swift`, `Notifications.swift`, `ScreenTime.swift`. Delete the
tests that only tested the deleted function:
`CallHistoryServiceTests.swift` (the two tests at `:8-20` that call it — if
that leaves the enclosing class empty, delete the class too),
`NotificationsServiceTests.testCoreDataTimestampSubtractsReferenceOffset`,
`ScreenTimeServiceTests.testCoreDataTimestampSubtractsReferenceOffset` and
`ScreenTimeServiceTests.testCoreDataTimestampRoundTripsThroughReferenceDate`.

**A4.** In `App/Services/Photos.swift`:
- change `final class PhotoService: NSObject, Service {` to
  `final class PhotoService: Service {`;
- delete `photoFetchTargetSize(maxDimension:)`, and in `fetchImageValue`
  replace `let targetSize = photoFetchTargetSize(maxDimension: maxDimension)`
  with `let targetSize = CGSize(width: maxDimension, height: maxDimension)`;
- delete `testFetchImageTargetSizeIsBoundedByMaxDimension` from
  `iMCPTests/PhotoServiceTests.swift`.

  If plan 038 changed how `maxDimension` is parsed, keep 038's parsing; the
  only requirement is that the value reaching `fetchImageValue` is already
  at least 1. If it is not guaranteed to be, STOP.

  These are the only edits this plan makes to `Photos.swift`. Nothing in the
  file needs `NSObject`: the place-name lookup uses static functions and a
  continuation, not a delegate.

**Verify**:
```console
git grep -n "coreDataTimestamp\|readLibraryArchive\|photoFetchTargetSize\|func integration" -- App iMCPTests ; echo "grep=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh --app-only
```
→ no matches and `grep=1`; `exit=0`; all tests pass.

**Commit**: `refactor: delete unused helpers and inline coreDataTimestamp`

---

### Unit B: Treat `$null` as nil in the iPhone notification archive

In `App/Services/RemoteNotificationsStore.swift`, inside `KeyedArchiveGraph`:

- In `string(_:maximumDepth:)`, after the `dereference` line, add the same
  check `array` already has, returning nil:
  `if case .string("$null") = object { return nil }`
- In `date(_:maximumDepth:)`, add the identical line after its `dereference`
  line.

Do not change `dereference`, `array` or `dictionary`.

**Test** — add to `iMCPTests/NotificationsServiceTests.swift`, next to
`testRemoteArchiveDecoderDecodesSyntheticKeyedArchive` (the model to follow).
A Swift dictionary cannot hold nil, so archive a small `NSCoding` object
instead; the decoder accepts any object whose fields carry the
`AppNotification...` keys. Put this class at file scope at the bottom of the
test file:

```swift
/// Archives the way the real store does when a notification has no title:
/// `encode(nil, forKey:)` writes a reference to the archive's `$null` object.
private final class NilTitleNotificationFixture: NSObject, NSCoding {
    override init() {}
    init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode("native-1" as NSString, forKey: "AppNotificationIdentifier")
        coder.encode(Date(timeIntervalSinceReferenceDate: 123) as NSDate, forKey: "AppNotificationCreationDate")
        coder.encode(nil, forKey: "AppNotificationTitle")
        coder.encode("Body" as NSString, forKey: "AppNotificationMessage")
    }
}
```

Test `testRemoteArchiveDecoderMapsNullStringsToNil`: archive
`[NilTitleNotificationFixture()]` with
`NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding: false)`,
decode with `RemoteNotificationArchiveDecoder().decodeDeliveredNotifications(_:bundleIdentifier:)`,
assert one record, `title == nil`, `subtitle == nil`, `body == "Body"`.

Run the new test **before** making the source change and confirm it fails
with `title` equal to `"$null"`. If it fails for a different reason (for
example the decoder throws), STOP: the fixture does not reproduce the defect.

**Verify**: `Scripts/test.sh --only iMCPTests/NotificationsServiceTests` → all pass, including the new test.

**Commit**: `fix(notifications): return nil, not "$null", for absent iPhone notification text`

---

### Unit C: Photos place-name lookup — keep it (check only)

**Make no edit in this unit and make no commit.** The unit letter is kept so
references to Units D to I stay valid. Its only job is to confirm that Unit A
left the place-name lookup intact and that you do not remove it later.

Do not delete or change `maxGeocodeLookupsPerSearch`, the Photos
`geocodeTimeout`, `GeocodeTimeoutError`, `photoPlaceCacheKey`,
`PlaceNameCache`, `placeNameCache`, `lookupPlaceNames(for:)`,
`reverseGeocodePlaceName(for:using:)`, the merge loop that sets
`metadata["placeName"]`, the `photos_search` description, the class
`PlaceNameCacheTests`, or the three `testPlaceCacheKey...` tests. Do not move
this code onto `withDeadline` (Unit I); it keeps its own timeout.

**Verify**:
```console
grep -c "func lookupPlaceNames\|func reverseGeocodePlaceName\|final class PlaceNameCache\|struct GeocodeTimeoutError\|func photoPlaceCacheKey" App/Services/Photos.swift
grep -c 'metadata\["placeName"\]' App/Services/Photos.swift
grep -c "final class PlaceNameCacheTests\|final class LocationRoundingTests" iMCPTests/PlaceNameCacheTests.swift
grep -c "func testPlaceCacheKey" iMCPTests/PhotoServiceTests.swift
git diff --stat main...HEAD -- iMCPTests/PlaceNameCacheTests.swift
Scripts/test.sh --only iMCPTests/PhotoServiceTests --only iMCPTests/PlaceNameCacheTests
```
→ `5`; `1`; `2`; `3`; empty output; all pass.

**Commit**: none.

---

### Unit D: Shortcuts — drain stderr while running, never fail a run that succeeded

In `App/Services/Shortcuts.swift`:

1. Change `private final class PipeBuffer` to `final class PipeBuffer` and add
   below it one shared helper (file scope, not private, so a test can call it):

   ```swift
   /// Collects a pipe's output as it arrives. A child that writes more than a
   /// pipe holds (about 64 KB) blocks until someone reads, so reading only
   /// after exit can hang it forever.
   func drain(_ pipe: Pipe) -> PipeBuffer {
       let buffer = PipeBuffer()
       pipe.fileHandleForReading.readabilityHandler = { handle in
           let data = handle.availableData
           if !data.isEmpty {
               buffer.append(data)
           }
       }
       return buffer
   }
   ```

2. In `listShortcuts`, replace the two `PipeBuffer()` declarations and the two
   `readabilityHandler = { ... }` blocks with
   `let outputBuffer = drain(outputPipe)` and `let errorBuffer = drain(errorPipe)`.
   Keep the existing `defer` that sets both handlers to nil and closes the
   handles.

3. In `runShortcut`:
   - after `process.standardError = errorPipe` add
     `let errorBuffer = drain(errorPipe)`;
   - change the `defer` to
     `defer { errorHandle.readabilityHandler = nil; errorHandle.closeFile() }`
     (on two lines);
   - delete `var errorData = Data()`;
   - in the `catch` block replace
     `errorData = (try? errorHandle.readToEnd()) ?? Data()` with
     `let errorData = errorBuffer.value()`;
   - delete the block `if errorData.isEmpty { errorData = ... }` and put
     `let errorData = errorBuffer.value()` in its place.

4. Add a file-scope function and use it in `runShortcut` in place of the
   `let output: String?` / `do` / `catch` block:

   ```swift
   /// The shortcut has already run by the time this is read, so nothing here
   /// may throw: a missing file means no output, and bytes that are not UTF-8
   /// are kept with replacement characters rather than reported as a failure.
   func shortcutOutputText(at url: URL) -> String? {
       (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
   }
   ```

   `let output = shortcutOutputText(at: outputFileURL)`

**Tests** — add a new class `ShortcutsServiceTests` at the bottom of
`iMCPTests/NotesServiceTests.swift` (an existing file; do not create a new
one). Model the temp-file handling on `CallHistorySearchTests`
(`iMCPTests/CallHistoryServiceTests.swift:25-48`).

- `testOutputTextKeepsNonUTF8Bytes`: write `Data([0x68, 0xFF, 0x69])` to a
  temp file; assert `shortcutOutputText(at:) == "h\u{FFFD}i"`.
- `testOutputTextIsNilWhenFileIsMissing`: a path that does not exist → `nil`.
- `testDrainLetsAChildWriteMoreThanAPipeHolds`: create a `Process` with
  `executableURL = URL(fileURLWithPath: "/bin/sh")` and
  `arguments = ["-c", "head -c 300000 /dev/zero >&2"]`, a `Pipe` as
  `standardError`, call `drain(pipe)`, set a `terminationHandler` that
  fulfils an `XCTestExpectation`, `try process.run()`, wait up to 10 s, then
  assert `process.terminationStatus == 0`. Set
  `pipe.fileHandleForReading.readabilityHandler = nil` in a `defer`. Do not
  assert an exact byte count (the last chunk may arrive after exit); asserting
  that the child exits is the regression test. Without `drain` this test
  times out.

**Verify**:
```console
grep -c "readToEnd" App/Services/Shortcuts.swift
grep -c "readabilityHandler = {" App/Services/Shortcuts.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh --only iMCPTests/ShortcutsServiceTests
```
→ `0`; `1`; `exit=0`; 3 tests pass.

**Commit**: `fix(shortcuts): drain stderr while a shortcut runs; never fail a run over its output encoding`

---

### Unit E: Notes — run AppleScript off the main thread

In `App/Services/Notes.swift`:

1. Add at file scope, below `notesAutomationActivatedKey`:

   ```swift
   /// NSAppleScript is not thread-safe, so every script runs on this one
   /// serial queue. It must not be the main queue: a script can take seconds,
   /// and the main queue also drives the menu bar and accepts connections.
   private let notesScriptQueue = DispatchQueue(label: "me.mattt.iMCP.notes.applescript")
   ```

2. Rename the existing `runAppleScript` to
   `private static func executeAppleScript(_ source: String) throws -> NSAppleEventDescriptor`,
   remove `@MainActor` and its doc comment, and leave its body unchanged.

3. Add the new entry point with the old name, so the four call sites
   (`try await self.runAppleScript(...)`) stay as they are:

   ```swift
   /// Runs an AppleScript on `notesScriptQueue` and maps Automation-permission
   /// errors to a clear message.
   private func runAppleScript(_ source: String) async throws -> NSAppleEventDescriptor {
       try await withCheckedThrowingContinuation { continuation in
           notesScriptQueue.async {
               continuation.resume(with: Result { try Self.executeAppleScript(source) })
           }
       }
   }
   ```

4. `final class NotesService: NSObject, Service` — run
   `grep -n "override\|#selector" App/Services/Notes.swift`. If there are no
   matches, drop `NSObject, ` as in Unit A4. If there are matches, leave it.

There is no unit test for this unit: any test that runs a script through this
path writes the real `notesAutomationActivated` default, and a script that
targets Notes shows an Automation prompt. Existing `NotesServiceTests` must
still pass.

**Verify**:
```console
grep -c "@MainActor" App/Services/Notes.swift
grep -c "notesScriptQueue.async" App/Services/Notes.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh --only iMCPTests/NotesServiceTests
```
→ `0`; `1`; `exit=0`; all pass.

If the build fails with a Sendable or "sending" diagnostic on
`NSAppleEventDescriptor`, STOP and report the exact diagnostic. Do not add
`@unchecked Sendable`, `nonisolated(unsafe)` or `@preconcurrency`.

**Operator check (not for the executor)**: this unit changes the thread
AppleScript runs on. It is safe by the documented contract (one thread at a
time) but cannot be proven by a unit test. In your report, ask the operator to
call `notes_folders` and `notes_search` once from an MCP client after the next
install and confirm they return and the menu bar stays responsive.

**Commit**: `fix(notes): run AppleScript on a serial queue instead of the main thread`

---

### Unit F: One read-only SQLite handle, one `SQLITE_TRANSIENT`, one home directory

**F1. Add the shared type.** In `App/Services/BookmarkedSQLiteStore.swift` add
`import SQLite3` and, at file scope above `BookmarkedSQLiteStore`:

```swift
/// SQLite copies a bound string or blob before the bind call returns.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A read-only SQLite connection. When `scopedURL` is given, its security
/// scope stays open until the connection closes, because SQLite opens the
/// `-wal`/`-shm` siblings lazily at query time, after `init` returns.
final class ReadOnlySQLite {
    struct OpenError: LocalizedError {
        let message: String
        var errorDescription: String? { "Failed to open database: \(message)" }
    }

    let handle: OpaquePointer
    private let scopedURL: URL?

    /// `immutable` skips locking and the write-ahead log, so a database held
    /// open by another app can still be read, possibly slightly stale.
    init(path: String, holdingAccessTo scopedURL: URL? = nil, immutable: Bool = false) throws {
        if let scopedURL, !scopedURL.startAccessingSecurityScopedResource() {
            throw BookmarkedSQLiteStore.AccessError.securityScopeAccessFailed
        }
        var handle: OpaquePointer?
        let status =
            immutable
            ? sqlite3_open_v2("file:\(path)?immutable=1", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            : sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            scopedURL?.stopAccessingSecurityScopedResource()
            throw OpenError(message: message)
        }
        self.handle = handle
        self.scopedURL = scopedURL
    }

    deinit {
        sqlite3_close(handle)
        scopedURL?.stopAccessingSecurityScopedResource()
    }
}
```

(`sqlite3_close(nil)` is a documented no-op.)

**F2. Delete the three private `SQLITE_TRANSIENT` copies** in
`BrowserHistory.swift`, `Notifications.swift`,
`Location/LocationHistoryStore.swift`. In `Messages.swift` delete
`private static let transient = ...` in `AttachmentReader` and change its one
use `Self.transient` to `SQLITE_TRANSIENT`.

**Verify F1+F2**: build → `exit=0`. `git grep -c "unsafeBitCast(-1" -- App` →
exactly one file, `App/Services/BookmarkedSQLiteStore.swift:1`.

**F3. Switch the four databases.** In each class below, replace the stored
properties `db` and `scopedURL` with one `private let connection: ReadOnlySQLite`,
add `private var db: OpaquePointer { connection.handle }` so the query code
does not change, delete the `deinit`, delete the "Security-scoped URL kept
accessible..." comment (it now lives on `ReadOnlySQLite`), and replace the
`init` body:

- `CallHistoryService.CallHistoryDatabase` (`CallHistory.swift`), keeping the
  signature `init(path: String, holdingAccessTo scopedURL: URL? = nil) throws`:
  `connection = try ReadOnlySQLite(path: path, holdingAccessTo: scopedURL)`.
  Then delete the now-unused `databaseOpenFailed` case of `DatabaseAccessError`
  and its `errorDescription` arm — **unless** plan 042 made
  `DatabaseAccessError` a `ClientFacingError`. In that case keep the case and
  write the init as
  `do { connection = try ReadOnlySQLite(...) } catch let error as ReadOnlySQLite.OpenError { throw DatabaseAccessError.databaseOpenFailed(error.message) }`.
- `KnowledgeDatabase` (`ScreenTime.swift`): same, and the same rule for
  `DatabaseError.openFailed`.
- `NotificationsDatabase` (`Notifications.swift`): keep the status
  classification, which the notification source relies on:

  ```swift
      init(path: String, holdingAccessTo scopedURL: URL? = nil) throws {
          do {
              connection = try ReadOnlySQLite(path: path, holdingAccessTo: scopedURL)
          } catch is ReadOnlySQLite.OpenError {
              let status: NotificationSourceStatus
              if access(path, F_OK) != 0, errno == ENOENT {
                  status = .unavailable
              } else if access(path, R_OK) != 0, errno == EACCES || errno == EPERM {
                  status = .denied
              } else {
                  status = .malformed
              }
              log.error("Failed to open notifications database")
              throw LocalNotificationSourceError.databaseOpenFailed(status)
          }
      }
  ```

  A `securityScopeAccessFailed` error must still propagate unchanged;
  `LocalNotificationSource.fetch` catches it by name.
- `BrowserHistoryDatabase` (`BrowserHistory.swift`):
  `connection = try ReadOnlySQLite(path: browser.databasePath, immutable: true)`.
  Keep the existing comment about `immutable=1` only if it adds something the
  doc comment on `ReadOnlySQLite.init` does not; otherwise delete it.

Do not touch `Messages.swift` `AttachmentReader.init`.

**F4. Home directory.** Replace `"/Users/\(NSUserName())"` with
`NSHomeDirectory()` in the five places: `BrowserHistory.swift`
(`let home = NSHomeDirectory()`), and the path constants in `CallHistory.swift`,
`Messages.swift`, `Notifications.swift`, `ScreenTime.swift`, each becoming
`NSHomeDirectory() + "/Library/..."` with the rest of the path unchanged.

**Test** — add to `iMCPTests/CallHistoryServiceTests.swift`, in
`CallHistorySearchTests` (it already builds a fixture database at `path`):

- `testReadOnlyConnectionOpensImmutable`:
  `XCTAssertNoThrow(try ReadOnlySQLite(path: path, immutable: true))`.
- `testReadOnlyConnectionReportsAMissingFile`: opening
  `path + ".absent"` throws an error that is a `ReadOnlySQLite.OpenError`.

**Verify**:
```console
git grep -n "NSUserName" -- App ; echo "grep=$?"
git grep -c "sqlite3_open_v2" -- App/Services/CallHistory.swift App/Services/ScreenTime.swift App/Services/Notifications.swift App/Services/BrowserHistory.swift ; echo "grep=$?"
git grep -c "stopAccessingSecurityScopedResource" -- App/Services
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh --only iMCPTests/CallHistorySearchTests --only iMCPTests/NotificationsServiceTests --only iMCPTests/BrowserHistoryServiceTests
```
→ no matches, `grep=1`; no matches, `grep=1`; only
`App/Services/BookmarkedSQLiteStore.swift` is listed; `exit=0`; all pass.

**Commit**: `refactor: share one read-only SQLite handle across the database services`

---

### Unit G: Screen Time — clip sessions to the range; one row loop, one schema, one envelope

All edits are in `App/Services/ScreenTime.swift` unless stated.

**G1. Simplify the default range.** Delete `screenTimeDefaultRange(now:)`. In
`resolveRange` delete `let defaultRange = screenTimeDefaultRange()` and replace
the `endDate` line and the three-way branch with:

```swift
        let endDate = parsedEnd ?? Date()
        var startDate = parsedStart ?? endDate.addingTimeInterval(-defaultRangeDuration)
```

Delete `testDefaultRangeSpansSevenDaysEndingNow` from
`iMCPTests/ScreenTimeServiceTests.swift`. The four `testResolveRange...` tests
there cover this function and must pass unchanged. If plan 038 rewrote
`resolveRange`, apply the same reduction to whatever shape it has now and keep
038's validation.

**G2. One schema, one envelope.** Add at file scope:

```swift
private let startDateSchema: JSONSchema = .string(
    description: "Start of the date range (inclusive, ISO 8601). Defaults to 7 days ago.",
    format: .dateTime
)
private let endDateSchema: JSONSchema = .string(
    description: "End of the date range (exclusive, ISO 8601). Defaults to now.",
    format: .dateTime
)
```

and use `"startDate": startDateSchema, "endDate": endDateSchema,` in all three
tools. (If plan 038 or 039 changed these descriptions, the constants take the
current text; the three copies must already be identical — if they are not,
STOP.) Add to `ScreenTimeService`:

```swift
    private static func itemList(_ items: [Value], start: Date, end: Date) -> Value {
        [
            "@context": "https://schema.org",
            "@type": "ItemList",
            "startDate": .string(start.localISO8601),
            "endDate": .string(end.localISO8601),
            "itemListElement": .array(items),
        ]
    }
```

and return `Self.itemList(items, start: startDate, end: endDate)` from each
tool. If the dictionary literal does not type-check as `Value`, copy the exact
literal form the tools use today.

**G3. One row loop, rows as `Value`.** In `KnowledgeDatabase`:

- Change `private final class KnowledgeDatabase` to `final class KnowledgeDatabase`
  (so it can be tested; its `init(path:holdingAccessTo:)` already has the
  default the test needs).
- Delete the four entry structs (`UsageEntry`, `DailyUsageEntry`,
  `WebUsageEntry`, `DeviceActivityEntry`).
- Add one helper:

  ```swift
      /// Runs a query whose `?1` and `?2` are the range start and end as Core
      /// Data timestamps and whose `?3`, if present, is the row limit.
      private func rows(
          _ sql: String,
          start: Date,
          end: Date,
          limit: Int? = nil,
          _ row: (OpaquePointer) -> Value?
      ) throws -> [Value] {
          var statement: OpaquePointer?
          guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
              throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
          }
          defer { sqlite3_finalize(statement) }

          sqlite3_bind_double(statement, 1, start.timeIntervalSinceReferenceDate)
          sqlite3_bind_double(statement, 2, end.timeIntervalSinceReferenceDate)
          if let limit {
              sqlite3_bind_int(statement, 3, Int32(clamping: limit))
          }

          var result: [Value] = []
          while true {
              let status = sqlite3_step(statement)
              if status == SQLITE_DONE { return result }
              guard status == SQLITE_ROW else {
                  throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
              }
              if let value = row(statement) {
                  result.append(value)
              }
          }
      }
  ```

- Rewrite each fetch function as SQL plus a row closure that builds the same
  object the tool closure builds today, returning `[Value]`. Example:

  ```swift
      func fetchUsage(start: Date, end: Date, limit: Int) throws -> [Value] {
          try rows(Self.usageSQL, start: start, end: end, limit: limit) { statement in
              guard let bundle = sqlite3_column_text(statement, 0) else { return nil }
              return [
                  "bundleIdentifier": .string(String(cString: bundle)),
                  "totalSeconds": .int(Int(sqlite3_column_double(statement, 1).rounded())),
                  "sessions": .int(Int(sqlite3_column_int64(statement, 2))),
              ]
          }
      }
  ```

  The keys and value types per tool must be exactly what the tools emit today:
  usage `bundleIdentifier`, `totalSeconds`, `sessions`; daily `date`,
  `bundleIdentifier`, `totalSeconds`, `sessions`; web `domain`, `totalSeconds`,
  `visits`; device `date`, `activeSeconds`, `firstOn`, `lastOff`, the last two
  as `Date(timeIntervalSinceReferenceDate:).localISO8601` strings. Whether the
  SQL is a `static let` or a local `let` is your choice.
- In the tool closures delete the `.map { entry in ... }` blocks: `items` is
  now the fetch result.

**G4. Clip sessions to the range.** In all four queries use numbered
parameters and clip. The rule, applied to each:

- duration: `SUM(MIN(ZENDDATE, ?2) - MAX(ZSTARTDATE, ?1))` (in SQLite,
  two-argument `MIN`/`MAX` are scalar functions);
- filter: `ZSTARTDATE < ?2 AND ZENDDATE > ?1` (replaces
  `ZSTARTDATE >= ? AND ZSTARTDATE < ?`);
- day bucket, where there is one:
  `date(MAX(ZSTARTDATE, ?1) + \(Int(coreDataReferenceOffset)), 'unixepoch', 'localtime')`,
  so a session that began before the range is bucketed on the range's first
  day, not on a day outside it;
- limit: `?3`.

The four queries in full:

```sql
-- usage
SELECT ZVALUESTRING AS bundle,
       SUM(MIN(ZENDDATE, ?2) - MAX(ZSTARTDATE, ?1)) AS total,
       COUNT(*) AS sessions
FROM ZOBJECT
WHERE ZSTREAMNAME = '/app/usage'
  AND ZVALUESTRING IS NOT NULL
  AND ZSTARTDATE < ?2
  AND ZENDDATE > ?1
GROUP BY ZVALUESTRING
ORDER BY total DESC
LIMIT ?3
```

```sql
-- daily usage  (DAY = date(MAX(ZSTARTDATE, ?1) + <offset>, 'unixepoch', 'localtime'))
SELECT day, bundle, total, sessions FROM (
    SELECT DAY AS day,
           ZVALUESTRING AS bundle,
           SUM(MIN(ZENDDATE, ?2) - MAX(ZSTARTDATE, ?1)) AS total,
           COUNT(*) AS sessions,
           ROW_NUMBER() OVER (
               PARTITION BY DAY
               ORDER BY SUM(MIN(ZENDDATE, ?2) - MAX(ZSTARTDATE, ?1)) DESC
           ) AS rank
    FROM ZOBJECT
    WHERE ZSTREAMNAME = '/app/usage'
      AND ZVALUESTRING IS NOT NULL
      AND ZSTARTDATE < ?2
      AND ZENDDATE > ?1
    GROUP BY day, bundle
)
WHERE rank <= ?3
ORDER BY day ASC, total DESC
```

```sql
-- web usage
SELECT metadata.Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN AS domain,
       SUM(MIN(object.ZENDDATE, ?2) - MAX(object.ZSTARTDATE, ?1)) AS total,
       COUNT(*) AS visits
FROM ZOBJECT object
JOIN ZSTRUCTUREDMETADATA metadata
  ON object.ZSTRUCTUREDMETADATA = metadata.Z_PK
WHERE object.ZSTREAMNAME = '/app/webUsage'
  AND metadata.Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN IS NOT NULL
  AND object.ZSTARTDATE < ?2
  AND object.ZENDDATE > ?1
GROUP BY domain
ORDER BY total DESC
LIMIT ?3
```

```sql
-- device activity  (DAY as above)
SELECT DAY AS day,
       SUM(MIN(ZENDDATE, ?2) - MAX(ZSTARTDATE, ?1)) AS total,
       MIN(MAX(ZSTARTDATE, ?1)) AS firstOn,
       MAX(MIN(ZENDDATE, ?2)) AS lastOff
FROM ZOBJECT
WHERE ZSTREAMNAME = '/display/isBacklit'
  AND ZVALUEINTEGER = 1
  AND ZSTARTDATE < ?2
  AND ZENDDATE > ?1
GROUP BY day
ORDER BY day ASC
```

Write `DAY` out as the full `date(...)` expression in Swift (one local
`let day = "date(MAX(ZSTARTDATE, ?1) + \(Int(coreDataReferenceOffset)), 'unixepoch', 'localtime')"`
interpolated into both day queries). Do not add or change any `ZSOURCE`
condition.

**Tests** — add a class `ScreenTimeQueryTests` at the bottom of
`iMCPTests/ScreenTimeServiceTests.swift` (add `import SQLite3`). Model
`setUpWithError` / `tearDownWithError` on `CallHistorySearchTests`
(`iMCPTests/CallHistoryServiceTests.swift:25-48`). Fixture schema:

```sql
CREATE TABLE ZOBJECT (Z_PK INTEGER PRIMARY KEY, ZSTREAMNAME TEXT, ZVALUESTRING TEXT,
  ZVALUEINTEGER INTEGER, ZSTARTDATE REAL, ZENDDATE REAL, ZSTRUCTUREDMETADATA INTEGER);
CREATE TABLE ZSTRUCTUREDMETADATA (Z_PK INTEGER PRIMARY KEY,
  Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN TEXT);
```

Rows for stream `/app/usage`, bundle `com.example.app`, as (start, end) Core
Data seconds: `(900, 1100)`, `(1500, 1600)`, `(1900, 2500)`, `(100, 200)`,
`(2000, 2100)`. Query range: `Date(timeIntervalSinceReferenceDate: 1000)` to
`Date(timeIntervalSinceReferenceDate: 2000)`.

- `testUsageClipsSessionsToTheRange`: `fetchUsage(limit: 10)` returns one
  object with `totalSeconds == 300` and `sessions == 3`. (Before G4 this
  returns 700 and 2 — run it before G4 if you want to see the failure.)
- `testDailyUsageBucketsAnEarlySessionInsideTheRange`: `fetchDailyUsage`
  returns rows whose `totalSeconds` sum to 300.
- `testWebUsageClipsSessionsToTheRange`: one `/app/webUsage` row
  `(900, 1100)` joined to a metadata row with domain `example.com` →
  `totalSeconds == 100`, `visits == 1`.
- `testDeviceActivityClipsFirstOnAndLastOff`: `/display/isBacklit` rows with
  `ZVALUEINTEGER = 1` at `(900, 1100)` and `(1900, 2500)` → the rows'
  `activeSeconds` sum to 200. Do not assert the `date` string or the exact
  `firstOn`/`lastOff` text: both depend on the machine's time zone.

Read values with `row.objectValue?["totalSeconds"]?.intValue`.

**Verify**:
```console
grep -c "while true" App/Services/ScreenTime.swift
grep -c "screenTimeDefaultRange\|struct .*Entry" App/Services/ScreenTime.swift
grep -c "ZSTARTDATE >= ?" App/Services/ScreenTime.swift
grep -c "ZSOURCE" App/Services/ScreenTime.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh --only iMCPTests/ScreenTimeServiceTests --only iMCPTests/ScreenTimeQueryTests
```
→ `1`; `0`; `0`; `0`; `exit=0`; all pass, including 4 new tests.

**Commit**: `fix(screentime): clip sessions to the requested range; share one query loop`

---

### Unit H: Encode images without the TIFF round-trip; screenshots default to JPEG

**H1.** In `App/Extensions/AppKit+Extensions.swift` replace the whole
`extension NSImage` with:

```swift
extension NSImage {
    func pngData() -> Data? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)?.pngData()
    }

    func jpegData(compressionQuality: Double) -> Data? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)?
            .jpegData(compressionQuality: compressionQuality)
    }
}
```

`bitmap` is deleted. (`CGImage.jpegData` takes a `CGFloat`; `Double` converts
implicitly. If the compiler disagrees, write `CGFloat(compressionQuality)`.)

**Test first** — add to `iMCPTests/AppModelTests.swift`, directly after
`testClampedCaptureImageProducesExactPixelDimensions` (the model to follow):

`testImageEncodingKeepsPixelDimensions`: build an `NSBitmapImageRep` of
200 x 100 pixels exactly the way `clampedCaptureImage` does
(`App/Services/Capture.swift:43-55`), set `rep.size = NSSize(width: 100, height: 50)`
(so points differ from pixels, as on a Retina display), wrap it in
`NSImage(size: NSSize(width: 100, height: 50))` with `addRepresentation(rep)`.
For both `image.pngData()` and `image.jpegData(compressionQuality: 0.8)`:
unwrap the data, create `NSBitmapImageRep(data:)`, and assert
`pixelsWide == 200` and `pixelsHigh == 100`.

This test passes before H1 (the TIFF path keeps pixels) and **must still pass
after**. If it fails after H1, STOP: `cgImage(forProposedRect:)` is
resampling, and the helpers need a different way to reach the bitmap.

**H2.** In `App/Services/Capture.swift`, tool `capture_take_screenshot`:
change the schema default `ImageFormat.png.rawValue` to
`ImageFormat.default.rawValue`, and in the handler change
`?? ImageFormat.png.rawValue` to `?? ImageFormat.default.rawValue` and the
trailing `?? .png` to `?? .default`. PNG stays selectable through the `format`
enum. If plan 038 replaced this parsing with a helper, change only the default
it passes. Change nothing else in `Capture.swift`.

**Verify**:
```console
git grep -n "tiffRepresentation\|var bitmap" -- App ; echo "grep=$?"
git grep -c "ImageFormat.png" -- App/Services/Capture.swift ; echo "grep=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh --only iMCPTests/CaptureDimensionAndTimeoutTests
```
→ no matches, `grep=1`; no matches, `grep=1`; `exit=0`; all pass.
(`--only` takes a test **class**, not a file. `CaptureDimensionAndTimeoutTests`
is the class in `AppModelTests.swift` that holds
`testClampedCaptureImageProducesExactPixelDimensions`; put the new test in it.)

**Commit**: `perf(capture): encode images without a TIFF copy; default screenshots to JPEG`

---

### Unit I: Maps — async MapKit, one deadline, correct radius and street address

All edits are in `App/Services/Maps.swift` unless stated.

**I1. Add the shared deadline helper** to
`App/Extensions/Foundation+Extensions.swift` (file scope):

```swift
/// Returns `operation`'s result, or throws `timeoutError` if it has not
/// finished within `limit`. On timeout the operation is abandoned rather than
/// awaited: framework calls such as MapKit's do not all honour task
/// cancellation, and waiting for one that never calls back would defeat the
/// deadline. The timer is cancelled as soon as the operation finishes.
func withDeadline<T: Sendable>(
    _ limit: Duration,
    throwing timeoutError: any Error,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = ResumeGate()
    return try await withCheckedThrowingContinuation { continuation in
        let timer = Task {
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            if await gate.shouldResume() {
                continuation.resume(throwing: timeoutError)
            }
        }
        Task {
            let result: Result<T, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            timer.cancel()
            if await gate.shouldResume() {
                continuation.resume(with: result)
            }
        }
    }
}
```

The `guard ... != nil else { return }` is load-bearing: a cancelled timer must
return, not fall through and race the result for the gate.

**Tests** — add to `iMCPTests/AppModelTests.swift` a class `DeadlineTests`
with a small `private struct TimedOut: Error {}`:
- `testReturnsTheOperationResultBeforeTheDeadline`:
  `try await withDeadline(.seconds(5), throwing: TimedOut()) { 7 }` equals 7.
- `testThrowsTheTimeoutErrorWhenTheOperationIsSlow`: an operation that does
  `try await Task.sleep(for: .seconds(30)); return 7` under a
  `.milliseconds(50)` deadline throws `TimedOut`, and the test finishes in
  well under 5 s.
- `testRethrowsTheOperationError`: an operation that throws
  `ToolInputError("x")` surfaces as `ToolInputError`.

**Verify I1**: build → `exit=0`; `Scripts/test.sh --only iMCPTests/DeadlineTests` → 3 pass.

**I2. Deadlines and the timeout error.** At the top of the file replace
`private let geocodeTimeout: TimeInterval = 10` with:

```swift
private let geocodeDeadline: Duration = .seconds(10)
private let mapsDeadline: Duration = .seconds(30)
```

Add `case timedOut` to `MapsError` with the description
`"Apple Maps did not answer in time. Retrying shortly may succeed."`. If plan
042 already added an equivalent timeout case to `MapsError`, use that instead
and add nothing.

**I3. Rewrite the tool bodies.** The pattern for every tool: wrap the
**entire** existing closure body in `withDeadline`, and inside it replace the
continuation with the async MapKit call. Wrapping the whole body means the
closure captures only `arguments` and `self`, both already safe to capture;
do **not** create a MapKit object outside the `withDeadline` closure and use
it inside. Argument validation stays as plans 038/042 left it — move it, do
not rewrite it.

- `maps_search`:

  ```swift
          ) { arguments in
              try await withDeadline(mapsDeadline, throwing: MapsError.timedOut) {
                  // ...existing argument parsing and request building...
                  return try await MKLocalSearch(request: searchRequest).start().mapItems.map(Place.init)
              }
          }
  ```

  In the region block change both `latitudinalMeters: radius` and
  `longitudinalMeters: radius` to `radius * 2`, with the comment
  `// These are full extents, so a radius is half of each.`
  The `NSError` code 2 branch is deleted with the continuation.

- `maps_explore`: same shape;
  `return try await MKLocalSearch(request: request).start().mapItems.prefix(limit).map(Place.init)`.
  The code 8 branch is deleted. Leave its `radius` alone: that API takes a
  radius.

- `maps_directions`: resolve both endpoints concurrently, then route:

  ```swift
                  async let origin = self.getMapItem(
                      address: arguments["originAddress"]?.stringValue,
                      coordinates: arguments["originCoordinates"]?.objectValue
                  )
                  async let destination = self.getMapItem(
                      address: arguments["destinationAddress"]?.stringValue,
                      coordinates: arguments["destinationCoordinates"]?.objectValue
                  )
                  let directionsRequest = MKDirections.Request()
                  directionsRequest.source = try await origin
                  directionsRequest.destination = try await destination
                  // ...transportType as today...
                  do {
                      let response = try await MKDirections(request: directionsRequest).calculate()
                      guard !response.routes.isEmpty else { throw MapsError.noRoute(mode: requestedMode) }
                      return Trip(response)
                  } catch {
                      throw mapsRoutingError(from: error, mode: requestedMode)
                  }
  ```

  `mapsRoutingError` returns a non-`MKError` unchanged, so the `MapsError`
  thrown inside the `do` passes through it intact.

  If, and only if, the compiler rejects the two `async let` lines with a
  Sendable/"sending" diagnostic about `MKMapItem`, fall back to the two
  sequential `try await self.getMapItem(...)` calls as they are today, keep
  everything else, and say so in your report.

- `maps_eta`: same `do`/`catch` shape with
  `Trip(try await MKDirections(request: directionsRequest).calculateETA())`.

- `maps_generate` — in addition to the wrap:
  1. Change the tool description from "Render a static PNG map image centered
     on a coordinate" to "Render a static map image centered on a coordinate".
  2. Add one optional property after `mapType`:

     ```swift
                     "format": .string(
                         description:
                             "Image encoding. Defaults to jpeg for satellite and hybrid maps, png otherwise.",
                         enum: ImageFormat.allCases.map { .string($0.rawValue) }
                     ),
     ```

     and parse it after `mapType`:

     ```swift
                 let format =
                     arguments["format"]?.stringValue.flatMap(ImageFormat.init(rawValue:))
                     ?? (mapType == .satellite || mapType == .hybrid ? .jpeg : .png)
     ```

     If plan 038 introduced a helper for parsing an enum argument that
     rejects unknown values, use it here with the same default.
  3. Replace the `NSScreen` block with a size in points equal to the
     requested size:
     `options.size = CGSize(width: width, height: height)`
  4. Replace the continuation with:

     ```swift
                 let snapshot = try await MKMapSnapshotter(options: options).start()
                 // MapKit renders at the display's scale, so the image can have
                 // more pixels than requested. Redraw to exactly the requested size.
                 let image = clampedCaptureImage(snapshot.image, maxDimension: max(width, height))
                 let data = format == .png ? image.pngData() : image.jpegData(compressionQuality: 0.8)
                 guard let data else {
                     // keep the existing NSError code 15 here, with its message
                     // changed to "Failed to encode the map image"
                 }
                 return Value.data(mimeType: format.mimeType, data)
     ```

     The code 14 branch and the three `log.error("Map snapshot failed...")`
     lines inside the old continuation are deleted with it.

- `maps_geocode` / `maps_reverse_geocode`: change the calls to
  `try await withDeadline(geocodeDeadline, throwing: MapsError.timedOut) { try await self.geocodeAddress(address) }`
  and likewise for `self.reverseGeocode(latitude:longitude:)`. The tool
  descriptions already say "Gives up after 10 seconds"; leave them.

**I4. Geocoding without the continuation.** Delete `withGeocodeTimeout`
entirely. Rewrite the two functions on the async `CLGeocoder` API, keeping the
errors they throw today for "no result" (code 18 and code 20, or whatever plan
042 replaced them with):

```swift
    private func geocodeAddress(_ address: String) async throws -> Value {
        guard let placemark = try await CLGeocoder().geocodeAddressString(address).first,
            let location = placemark.location
        else {
            throw /* the existing "No location found for address" error */
        }
        return Self.placeValue(
            from: placemark,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
    }

    private func reverseGeocode(latitude: Double, longitude: Double) async throws -> Value {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = try await CLGeocoder().reverseGeocodeLocation(location).first else {
            throw /* the existing "No address found for location" error */
        }
        return Self.placeValue(from: placemark, latitude: latitude, longitude: longitude)
    }
```

**I5. Street address.** Add at file scope near `mapsMapType`:

```swift
/// A placemark splits a street address into the number (`subThoroughfare`)
/// and the street (`thoroughfare`).
func mapsStreetAddress(number: String?, street: String?) -> String? {
    let parts = [number, street].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}
```

and in `placeValue` replace the `if let thoroughfare` block with:

```swift
        if let street = mapsStreetAddress(
            number: placemark.subThoroughfare,
            street: placemark.thoroughfare
        ) {
            addressComponents["streetAddress"] = .string(street)
        }
```

**Tests** — add to `iMCPTests/PhotoServiceTests.swift`, next to
`testTransportTypeFromAnyIsAny` (that file already hosts the Maps helper
tests):
- `testStreetAddressJoinsNumberAndStreet`: `("1", "Infinite Loop")` →
  `"1 Infinite Loop"`; `(nil, "Infinite Loop")` → `"Infinite Loop"`;
  `("1", nil)` → `"1"`; `(nil, nil)` → `nil`.

Add to `iMCPTests/ToolErrorSanitizationTests.swift`? **No** — that file is not
in scope. Instead add to `PhotoServiceTests`:
- `testMapsTimeoutIsClientFacing`:
  `XCTAssertTrue((MapsError.timedOut as Error) is ClientFacingError)` and its
  `errorDescription` is non-empty. (Skip if plan 042's case was used and 042
  already tests it.)

**Verify**:
```console
grep -c "withCheckedThrowingContinuation\|ResumeGate\|NSScreen" App/Services/Maps.swift
grep -c "withDeadline(" App/Services/Maps.swift
grep -c "code: 2,\|code: 8,\|code: 14,\|code: 21," App/Services/Maps.swift
grep -c "radius \* 2" App/Services/Maps.swift
grep -c "mapsRoutingError(from: error" App/Services/Maps.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh --only iMCPTests/PhotoServiceTests --only iMCPTests/DeadlineTests --only iMCPTests/CaptureDimensionAndTimeoutTests
```
→ `0`; `7`; `0`; `2`; `2`; `exit=0`; all pass.

**Operator check (not for the executor)**: MapKit calls need the network and
cannot be unit tested. In your report ask the operator to call, after the next
install: `maps_search` with a `region`, `maps_directions` by address,
`maps_eta`, `maps_generate` once with `mapType: "standard"` and once with
`"satellite"` (confirm the returned image is exactly the requested width and
height), and `maps_geocode` for a street address (confirm the house number is
present).

**Commit**: `fix(maps): use async MapKit with one deadline; fix search radius and street numbers`

---

### Final step: Full gate

```console
swift format -i -r .
swift format lint --strict --recursive . ; echo "exit=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh
git status --short
git diff --shortstat main...HEAD
```

**Verify**: both `exit=0`; all tests in both suites pass; `git status` shows
only in-scope files (formatting changes to other files mean the tree was not
formatted before you started — revert those, do not commit them);
`--shortstat` shows more deletions than insertions. If formatting changed
in-scope files, commit that as `style: format`.

## Test plan

New tests, all in existing files (no `project.pbxproj` edit):

| Unit | File | Class | Tests | Modelled on |
|------|------|-------|-------|-------------|
| B | `iMCPTests/NotificationsServiceTests.swift` | `NotificationsServiceTests` | `testRemoteArchiveDecoderMapsNullStringsToNil` | `testRemoteArchiveDecoderDecodesSyntheticKeyedArchive` (same file) |
| D | `iMCPTests/NotesServiceTests.swift` | `ShortcutsServiceTests` (new class) | 3 | `CallHistorySearchTests` for temp files |
| F | `iMCPTests/CallHistoryServiceTests.swift` | `CallHistorySearchTests` | 2 | the tests already in that class |
| G | `iMCPTests/ScreenTimeServiceTests.swift` | `ScreenTimeQueryTests` (new class) | 4 | `CallHistorySearchTests` fixture set-up |
| H | `iMCPTests/AppModelTests.swift` | `CaptureDimensionAndTimeoutTests` | `testImageEncodingKeepsPixelDimensions` | that test |
| I | `iMCPTests/AppModelTests.swift` | `DeadlineTests` (new class) | 3 | — |
| I | `iMCPTests/PhotoServiceTests.swift` | `PhotoServiceTests` | `testStreetAddressJoinsNumberAndStreet`, `testMapsTimeoutIsClientFacing` | `testTransportTypeFromAnyIsAny` |

Tests deleted with the code they covered:
`testFetchImageTargetSizeIsBoundedByMaxDimension`,
`testDefaultRangeSpansSevenDaysEndingNow`, and the `coreDataTimestamp` tests
in three files.

Not covered by automated tests, and why: Notes threading (needs Automation
consent and writes real defaults) and all MapKit network calls. These are
the two "Operator check"
items above.

Verification: `Scripts/test.sh` → all pass, with 16 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `Scripts/test.sh` passes both suites
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `git grep -n "coreDataTimestamp\|readLibraryArchive\|photoFetchTargetSize\|screenTimeDefaultRange\|withGeocodeTimeout\|tiffRepresentation\|NSUserName" -- App iMCPTests` returns no matches
- [ ] `grep -c "withCheckedThrowingContinuation\|NSScreen" App/Services/Maps.swift` → `0`
- [ ] `grep -c "@MainActor" App/Services/Notes.swift` → `0`
- [ ] `grep -c "readToEnd" App/Services/Shortcuts.swift` → `0`
- [ ] `git grep -c "unsafeBitCast(-1" -- App` lists exactly one file
- [ ] `grep -c "ZSTARTDATE >= ?" App/Services/ScreenTime.swift` → `0`
- [ ] `grep -c "func lookupPlaceNames\|func reverseGeocodePlaceName\|final class PlaceNameCache\|struct GeocodeTimeoutError\|func photoPlaceCacheKey" App/Services/Photos.swift` → `5` (the place-name lookup is still there)
- [ ] `git diff --stat main...HEAD -- iMCPTests/PlaceNameCacheTests.swift` is empty
- [ ] `git diff --stat main...HEAD -- iMCP.xcodeproj` is empty
- [ ] `git diff --shortstat main...HEAD` shows deletions > insertions
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row for 049 updated (list which units are done if you stopped early)

## STOP conditions

Stop and report back (do not improvise) if:

- Plans 038 and 042 are not marked `DONE` and the operator has not said to
  proceed without them.
- A symbol named in a step no longer exists, or its logic (not just its
  argument parsing or error type) differs from the excerpt in "Current state".
- The Unit B test fails for any reason other than `title == "$null"` before
  the fix.
- `testImageEncodingKeepsPixelDimensions` (Unit H) fails after H1.
- The Unit E build fails with a Sendable/"sending" diagnostic on
  `NSAppleEventDescriptor`, or any Unit I tool closure fails with one that the
  step's stated fallback does not cover. Never silence a concurrency
  diagnostic with `@unchecked Sendable`, `nonisolated(unsafe)` or
  `@preconcurrency`.
- The three Screen Time date schemas are no longer identical to each other.
- A Screen Time fixture test fails after G4 with a SQLite error about `MIN`,
  `MAX` or `?1` — the SQL was transcribed wrongly; fix the transcription, and
  if it still fails, stop.
- You find yourself wanting to edit `iMCP.xcodeproj/project.pbxproj`, create a
  new test file, or touch `AttachmentReader.init` in `Messages.swift`.
- Any step seems to need a change to the `photos_search` place-name lookup,
  its tests, or `iMCPTests/PlaceNameCacheTests.swift`, or the Unit C verify
  does not give the expected counts.
- A step's verification fails twice after a reasonable fix attempt.
- Any step would need the Apple ID password, a 2FA code, a System Settings
  privacy change, or a reboot. None should; if one seems to, that is a HUMAN
  STEP — stop and hand off.

## Maintenance notes

- **Do not install.** The normal local-dev command after tests is
  `Scripts/install-local.sh run`. The executor must not run it unless the
  operator asks. The two operator checks (Notes, Maps) happen after the
  operator's next install.
- **Reviewer, look hardest at**:
  - `withDeadline`: the cancelled-timer `guard`, and that neither `Task` body
    can throw.
  - Unit E: AppleScript now runs on a private serial queue instead of the main
    thread. All compile-and-execute work is confined to that queue; the
    returned descriptor was already being read off the main actor before this
    change.
  - Unit G SQL: parameter numbering and that no `ZSOURCE` condition appeared.
  - Unit F: `NotificationsDatabase` still maps an open failure to
    `.unavailable` / `.denied` / `.malformed`, and
    `securityScopeAccessFailed` still propagates.
- **Behaviour changes a user can see**:
  - `maps_search` with a `region` now covers the full radius (four times the
    previous area).
  - `maps_generate` output is always exactly `width` x `height` pixels. On a
    Retina display it was already that size, but labels and features are now
    drawn at the size they would have on a standard display (smaller relative
    to the image than before). Satellite and hybrid maps come back as JPEG
    unless `format: "png"` is passed.
  - `capture_take_screenshot` returns JPEG unless `format: "png"` is passed.
  - Screen Time totals for a range change slightly at the edges: sessions
    straddling either end are now counted for their overlap only.
  - Geocode results include the house number in `streetAddress`, as
    `"<number> <street>"`. That order is wrong for locales that write the
    number after the street; `CLPlacemark.postalAddress?.street` (Contacts
    framework) gives the localised line and is the upgrade if this matters.
- **Deferred on purpose**:
  - `Photos.swift` `fetchImageValue` still JPEG-encodes inside the PhotoKit
    callback. Unit H makes that encode much cheaper; moving it out means
    passing a non-Sendable `NSImage` across a continuation and belongs in its
    own change.
  - `Shortcuts.swift`: a pipe's last chunk can still arrive after the process
    exits, in both `listShortcuts` (stdout, so a very long list could lose its
    tail) and `runShortcut` (stderr, error text only). Fixing it needs a final
    synchronous read coordinated with the handler.
  - Screen Time `ZSOURCE` device filter: the queries sum usage from every
    device that syncs to this Mac. Whether to filter to this device needs a
    look at real data first.
  - Screen Time per-day queries attribute a session that crosses local
    midnight wholly to the day it started.
  - `Messages.swift` `AttachmentReader` keeps its own SQLite open; its flags
    and lifetime differ from `ReadOnlySQLite`.
- **Considered and reversed: deleting the `photos_search` place-name
  lookup.** An earlier draft of this plan removed the reverse-geocode code
  and the `placeName` field, because the tool was annotated as local while
  sending rounded photo coordinates to Apple. The owner reversed that on
  2026-10-12: removing it loses a feature, and the real defect was only the
  wrong `openWorldHint`. `photos_search` therefore stays open-world
  (`read open`) in plan 039's annotation table and must not be flipped back
  to local. Plan 039 still contains notes written before this decision that
  say plan 049 deletes the lookup and that the row then becomes `read local`;
  those notes are superseded. The Photos lookup keeps its own 2 s timeout
  and does not use `withDeadline`.
- **If you add another MapKit or CoreLocation call**, wrap it in
  `withDeadline` and build every framework object inside the closure.
