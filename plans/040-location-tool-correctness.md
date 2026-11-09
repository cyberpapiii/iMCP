# Plan 040: Location tools return the newest history, reject bad places, ring the right device, and stop leaking raw error text

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- App/Services/Location.swift App/Services/Location/LocationHistoryStore.swift App/Services/Location/FindMyClient.swift App/Services/Location/VenueLookup.swift App/Services/Location/LocationSampler.swift iMCPTests/ICloudAuthFlowTests.swift iMCPTests/ICloudAuthPlumbingTests.swift iMCPTests/LocationRenewalAndTimelineTests.swift iMCPTests/LocationTimelineItemsTests.swift`
>
> Some drift is **expected**: this plan runs after plans 037, 038 and 039.
> Plan 038 changes how `limit` is parsed (`App/Models/FetchPolicy.swift` and
> possibly the `FetchPolicy.parse(...)` lines inside `Location.swift`), and
> plan 039 changes the `annotations:` blocks of `location_ring` and
> `location_place_set`. Line numbers below are from commit `8165d29` and will
> have moved; find each excerpt by its text. Treat it as a STOP condition only
> if the *logic* of an excerpt differs from what is quoted (for anything other
> than limit parsing and annotation hints).

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED — one client-visible response-shape change (`location_history`), isolated in Step 2
- **Depends on**: plans/037-isolate-tests-from-real-state.md, plans/038-validate-tool-arguments.md
- **Category**: bug
- **Planned at**: commit `8165d29`, 2026-10-12

## Why this matters

Six defects in the Location tools, all in code a client can reach today:

1. **`location_history` returns the wrong half of the data.** The store reads
   oldest-first and stops at `limit`. The sampler writes one fix every 10
   minutes, so the default 7-day range holds about 1,008 samples against a
   default limit of 500: the default call silently returns the *first* 3.5
   days and never the most recent ones, with nothing saying rows were dropped.
   `location_visits`, `location_timeline` and the `location_now` fallback share
   the same store call with `limit: 20_000` and lose the newest rows the same
   way once the range holds more than that.
2. **`location_place_set` accepts any numbers.** `latitude: 999`, `NaN`, a
   negative radius or a radius of `1e9` are all stored. A giant radius makes
   every stay everywhere report as that place. Renaming a place onto a name
   another place already has creates two places with one name, and every
   name-based lookup after that picks whichever sorts first.
3. **`location_ring` can ring the wrong device, repeatedly.** It takes the
   first of the user's devices with a matching name; two devices named
   "iPhone" are indistinguishable. Nothing limits how often a client can ring.
4. **A fix with no timestamp is recorded as 1 January 1970.**
5. **Raw system error text reaches MCP clients** through the health block of
   `location_now` / `location_timeline`, bypassing the project's rule that
   only `ClientFacingError` text crosses to a client.
6. **A failed venue lookup is cached as "no venues" until the app relaunches**,
   and the cache has no upper bound.

## Current state

All excerpts are from commit `8165d29`.

### Files and roles

- `App/Services/Location/LocationHistoryStore.swift` — `actor LocationHistoryStore`; SQLite store of recorded positions and named places. `samples(...)` (line 253) and `setPlace(...)` (line 424) are the two functions this plan changes.
- `App/Services/Location.swift` — `final class LocationService: Service`; defines every `location_*` tool as a `Tool(...) { arguments in ... }` closure inside `var tools`. Private `Encodable` report structs sit at the top of the file.
- `App/Services/Location/FindMyClient.swift` — `actor FindMyClient` (Apple Find My web API), `enum FindMyError`, and the JSON decoding helpers.
- `App/Services/Location/VenueLookup.swift` — `actor VenueLookup`; cached Apple Maps point-of-interest lookup.
- `App/Services/Location/LocationSampler.swift` — `actor LocationSampler`; the 10-minute recorder. Owns `LocationSamplerStatus.lastFailure`.
- `App/Controllers/ToolErrorResponse.swift` — defines `protocol ClientFacingError: LocalizedError` and `struct ToolInputError: ClientFacingError`. Do not modify.

### Defect 1 — oldest-first truncation

```swift
// App/Services/Location/LocationHistoryStore.swift:289-323
        let sql = """
            SELECT provider, subject_id, subject_kind, source_device_id,
                   device_id, device_name, person_name, is_me, latitude, longitude,
                   accuracy, position_type, timestamp
            FROM samples
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY timestamp ASC
            """
        ...
        var rows: [LocationSample] = []
        // Downsampling keeps the first sample in each bucket per device, so a
        // long range answers in a readable number of rows instead of thousands.
        var lastBucket: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let sample = Self.sample(from: statement)
            if let interval, interval > 0 {
                let bucket = Int(sample.timestamp.timeIntervalSince1970) / interval
                let identity = "\(sample.provider):\(sample.subjectID):\(sample.sourceDeviceID ?? "")"
                if lastBucket[identity] == bucket { continue }
                lastBucket[identity] = bucket
            }
            rows.append(sample)
            if rows.count >= limit { break }
        }
        return rows
```

Callers of `samples(...)` (confirm with `grep -rn "\.samples(" App`):
`Location.swift:504` (`location_history`, caller's limit), `:571`
(`location_visits`, `limit: 20_000`), `:1082` (`timeline(...)`, `20_000`),
`:1236` (`now(...)` fallback, `20_000`), and three in
`App/Views/LocationWindow.swift` (`:188`, `:213`, `:366`). Every caller wants
the newest rows when there are too many, and every caller expects ascending
order. None of them needs editing for the store fix.

The `location_history` handler returns a bare JSON array:

```swift
// App/Services/Location.swift:497-526
        ) { arguments in
            let policy = try FetchPolicy.parse(from: arguments, defaultLimit: 500)
            let range = Self.range(from: policy)
            let interval = arguments["intervalMinutes"]?.intValue.map { max($0, 0) * 60 }
            let includePeople = try await self.peopleHistoryAccess(
                requestedPerson: arguments["person"]?.stringValue
            )
            let samples = try await self.historyStore.samples(
                person: arguments["person"]?.stringValue,
                device: arguments["device"]?.stringValue,
                from: range.lowerBound,
                to: range.upperBound,
                everySeconds: interval,
                limit: max(policy.requestedLimit, 1),
                includePeople: includePeople
            )
            return samples.map {
                HistorySample(
                    person: $0.personName,
                    ...
                )
            }
        }
```

`HistorySample` is the private struct at `Location.swift:78-88`.

### Defect 2 — `location_place_set` validation and duplicate names

```swift
// App/Services/Location.swift:728
            let radius = arguments["radiusMeters"]?.numberValue ?? 150
// App/Services/Location.swift:737-741
            } else if let value = arguments["latitude"]?.numberValue,
                let other = arguments["longitude"]?.numberValue
            {
                latitude = value
                longitude = other
```

```swift
// App/Services/Location/LocationHistoryStore.swift:433-439
        let db = try connection()
        let existing = try places()
        let target = previousName ?? name
        let match = existing.first { $0.name.caseInsensitiveCompare(target) == .orderedSame }
        if previousName != nil, match == nil {
            throw LocationHistoryError.unknownPlace(target)
        }
```

The `places` table (`LocationHistoryStore.swift:596-606`) has `name TEXT NOT NULL`
and no uniqueness constraint. When `previousName` is set, `match` is the row
being renamed and nothing checks whether `name` already belongs to a
different row.

`setPlace` has a second production caller, the Location window
(`App/Views/LocationWindow.swift:443`), whose radius slider is `30 ... 400`.
Every existing test passes a radius between 40 and 200 and real coordinates.
`LocationHistoryError.invalidRequest(String)` already exists
(`LocationHistoryStore.swift:128-147`), is a `ClientFacingError`, and its
description is the string itself. The file already imports `CoreLocation`.

### Defect 3 — `location_ring`

```swift
// App/Services/Location.swift:434-455
            guard let name = arguments["device"]?.stringValue else {
                throw FindMyError.unknownDevice("")
            }
            let played = try await self.withFindMy { client -> String in
                let snapshot = try await client.snapshot()
                // Matched by name because that is what the caller saw; the id is
                // an opaque string no human or agent reads back.
                guard
                    let device = snapshot.devices.first(where: {
                        $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.ownerID == nil
                    })
                else {
                    throw FindMyError.unknownDevice(name)
                }
                guard device.canPlaySound else {
                    throw FindMyError.soundUnavailable(device.name)
                }
                try await client.playSound(deviceID: device.id)
                return device.name
            }
            return RingResult(device: played, played: true)
```

`location_devices` already reports each device's `id` (`DeviceReport.id`,
`Location.swift:65`), so a caller has a handle that distinguishes two
same-named devices; the ring tool just does not accept it.

```swift
// App/Services/Location/FindMyClient.swift:256-269
    /// Plays a sound on one of the user's own devices.
    func playSound(deviceID: String) async throws {
        guard let findMy = account.findMy else { throw FindMyError.notSignedIn }
        _ = try await send(
            path: "fmipservice/client/web/playSound",
            base: findMy,
            body: [
                "device": deviceID,
                "subject": "Find My iPhone Alert",
                "clientContext": ["fmly": true],
            ]
        )
        await noteSuccessfulOperation()
    }
```

`enum FindMyError` (`FindMyClient.swift:67-97`) is `ClientFacingError, Equatable`
with an exhaustive `switch` in `errorDescription`. Nothing else switches over
it (`grep -rn "FindMyError" App` shows only `throw`, one `catch
FindMyError.noDevices`, and one `== .notSignedIn`).

### Defect 4 — missing `timeStamp`

```swift
// App/Services/Location/FindMyClient.swift:326-341
    private static func fix(from raw: [String: Any]?) -> FindMyFix? {
        guard
            let raw,
            let latitude = raw["latitude"] as? Double,
            let longitude = raw["longitude"] as? Double
        else { return nil }
        // Apple reports the fix time in milliseconds since the epoch.
        let milliseconds = (raw["timeStamp"] as? Double) ?? 0
        return FindMyFix(
```

### Defect 5 — raw error text

```swift
// App/Services/Location/LocationSampler.swift:196-201
        } catch {
            // A sampler that stopped on the first network hiccup would leave a
            // silent hole in the history. The next tick tries again.
            status.lastFailure = error.localizedDescription
            log.error("Location sampling failed: \(error.localizedDescription, privacy: .public)")
        }
```

`status.lastFailure` is sent to clients as `HealthReport.lastSampleFailure`
(`Location.swift:1320`) and inside `healthMessage` (`Location.swift:1352`,
`" Last failure: \($0)"`).

```swift
// App/Services/Location.swift:1257
            let reason = (error as? ClientFacingError)?.errorDescription ?? error.localizedDescription
```

`reason` is interpolated into `HealthReport.message` at `Location.swift:1289`.

The project's existing sanitiser shape is "a `ClientFacingError`'s own
description, otherwise only the error's type name":

```swift
// App/Controllers/ICloudSession.swift:741-746  (private; shown as the pattern, do not call or edit)
    private static func detail(for error: Error) -> String {
        if let facing = error as? ICloudAuthError, let description = facing.errorDescription {
            return description
        }
        return String(describing: type(of: error))
    }
```

`FindMyError` and `ICloudAuthError` both conform to `ClientFacingError`, so the
errors that normally reach these two sites keep their full sentence.

### Defect 6 — venue cache

```swift
// App/Services/Location/VenueLookup.swift:55-63
    func venues(latitude: Double, longitude: Double, limit: Int = 3) async -> [NearbyVenue] {
        // Keyed to about 10 m so the same building always hits the cache.
        let key = String(format: "%.4f,%.4f", latitude, longitude)
        if let cached = cache[key] { return Array(cached.prefix(limit)) }
        let found = (try? await loader(latitude, longitude, Self.searchRadius)) ?? []
        let sorted = found.sorted { $0.meters < $1.meters }
        cache[key] = sorted
        return Array(sorted.prefix(limit))
    }
```

### Conventions that apply

- Swift 6 strict concurrency; **warnings are errors**. Deployment target macOS 15.1.
- An error's text reaches an MCP client only if the error conforms to
  `ClientFacingError` (`App/Controllers/ToolErrorResponse.swift`). A bad
  argument the caller can fix is `throw ToolInputError("...")`. Messages must
  be authored strings plus at most the caller's own argument echoed back.
- Tool handlers return an `Encodable` value; tests receive it as
  `ToolResult.json(Data)`.
- Tests call a tool as
  `try await XCTUnwrap(service.tools.first { $0.name == "location_history" })([...])`.
  Exemplar: `iMCPTests/LocationRenewalAndTimelineTests.swift`, class
  `LocationTimelineToolTests` (line 262), which has a temp-directory `store`,
  a `service()` factory, a `sample(minutesAgo:)` fixture, an `object(_:)`
  JSON helper and an `iso(_:)` date helper.
- Store-level tests: `iMCPTests/ICloudAuthFlowTests.swift`, class
  `LocationHistoryStoreTests` (line 1537), with `sample(secondsFromNow:)`.
- Find My client tests: same file, class `FindMyClientTests` (line 1153), with
  `makeClient(_:)`, `deviceListJSON` and `ScriptedTransport`.
  `ScriptedTransport.stub(fragment, status:, json:)` queues **one** reply per
  call; an unstubbed request answers HTTP 404. `transport.fail(fragment, with:)`
  queues one thrown error. `transport.requests(matching:)` lists what was sent.
- No new test files: test targets are not synchronized groups, and a new file
  needs four hand-made `project.pbxproj` entries. Every test in this plan goes
  into an existing file.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| One test class | `Scripts/test.sh --only iMCPTests/<TestClass>` (repeatable; implies app suite only) | all pass |
| App tests | `Scripts/test.sh --app-only` | all pass |
| Both suites | `Scripts/test.sh` | all pass |
| Format | `swift format -i -r .` | exit 0 |
| Format lint | `swift format lint --strict --recursive .` | exit 0 |

Never run `xcodebuild test -scheme iMCP` directly: the always-on watchdog
relaunches the installed app and breaks the test host. Never
`launchctl bootout` the always-on agent. Local Xcode is 27 beta and CI is
Xcode 26; avoid `Date.init` as a default argument and large literal fixtures.

## Scope

**In scope** (the only files you should modify):

- `App/Services/Location/LocationHistoryStore.swift`
- `App/Services/Location.swift`
- `App/Services/Location/FindMyClient.swift`
- `App/Services/Location/VenueLookup.swift`
- `App/Services/Location/LocationSampler.swift` (one line)
- `iMCPTests/ICloudAuthFlowTests.swift`
- `iMCPTests/ICloudAuthPlumbingTests.swift`
- `iMCPTests/LocationRenewalAndTimelineTests.swift`
- `iMCPTests/LocationTimelineItemsTests.swift`
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):

- `App/Views/LocationWindow.swift` — plan 047 owns it. It calls `samples(...)`
  and `setPlace(...)`; both keep their signatures, so it needs no edit.
- The `annotations:` blocks of `location_ring` and `location_place_set` — plan 039.
- Integer argument parsing and caps (`limit`, `intervalMinutes`,
  `minimumMinutes`), `App/Models/FetchPolicy.swift` — plan 038.
- The `log.error(... privacy: .public)` line at `LocationSampler.swift:200`
  and every other log-privacy change — plan 042.
- `App/Controllers/ICloudSession.swift` — plan 045. Its `detail(for:)` is
  quoted above only as the pattern.
- Sampler start/stop/generation logic — plan 047.
- A `location_place_delete` tool — plan 054.
- Address lookups in `report(for:person:geocoder:addresses:)`
  (`Location.swift:1002-1021`). They are already deduplicated per request by
  exact coordinate, and
  `testVisitsRetriesFailedAddressesAndKeepsNearbyCoordinatesDistinct` pins
  that nearby coordinates stay distinct. Leave them alone.
- `README.md` and `docs/` — plan 053.

## Git workflow

- Start from an up-to-date `main` with plans 037 and 038 merged.
- Branch: `advisor/040-location-tool-correctness`
- One commit per step that changes source, conventional-commit style, e.g.
  `fix(location): return the newest samples when history is truncated`.
  Repo examples: `fix: bring Settings forward from the menu; stay quiet on relaunch`,
  `feat(messages): add conversations, attachments, and chatId to messages_fetch`.
- Do NOT push or open a PR unless the operator instructed it. `origin`
  (`cyberpapiii/iMCP`) is the only writable remote; `upstream` (`mattt/iMCP`)
  must never receive pushes or PRs.

## Steps

### Step 1: Make the store keep the newest rows

File: `App/Services/Location/LocationHistoryStore.swift`, function `samples(...)`.

1. In the SQL, change `ORDER BY timestamp ASC` to `ORDER BY timestamp DESC`.
2. Change the final `return rows` to `return rows.reversed()`.
3. Replace the two-line comment above `var lastBucket` with one that is true
   for the new direction:

   ```swift
        // Read newest first so a full `limit` drops the oldest rows, never
        // the latest; the result goes back out in time order. Downsampling
        // keeps the newest sample in each bucket per device.
   ```

Do **not** add a SQL `LIMIT`. The row loop already stops at `limit`, and a SQL
limit would cut rows before downsampling (`everySeconds`) thins them, returning
fewer than `limit` rows when more qualify.

Nothing else in the function changes. Signature and return type stay
`[LocationSample]`, ascending by time.

**Verify**: `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` → exit 0.
**Verify**: `grep -n "ORDER BY timestamp" App/Services/Location/LocationHistoryStore.swift` → exactly one line, containing `DESC`.

Add to `LocationHistoryStoreTests` in `iMCPTests/ICloudAuthFlowTests.swift`
(next to `testDownsamplingKeepsOneSamplePerIntervalPerDevice`):

```swift
    func testAFullLimitKeepsTheNewestSamplesInTimeOrder() async throws {
        let samples = (0 ..< 5).map { sample(secondsFromNow: TimeInterval($0 * 60)) }
        _ = try await store.record(samples)

        let rows = try await store.samples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 2_000_000_000),
            limit: 2
        )

        XCTAssertEqual(rows, Array(samples.suffix(2)))
    }
```

**Verify**: `Scripts/test.sh --only iMCPTests/LocationHistoryStoreTests` → all pass, including the new test.

### Step 2: Tell `location_history` callers when rows were dropped

File: `App/Services/Location.swift`.

This is the plan's one client-visible shape change: `location_history` goes
from a bare array to `{"samples": [...], "truncated": true|false}`. Keep it in
its own commit.

1. Directly below `private struct HistorySample` (line 78), add:

   ```swift
   private struct HistoryReport: Encodable {
       let samples: [HistorySample]
       /// True when the range held more than `limit` samples. The ones
       /// returned are the newest.
       let truncated: Bool
   }
   ```

2. In the `location_history` handler, ask the store for one row more than the
   limit and report whether it arrived. Target shape:

   ```swift
            let limit = <the handler's existing limit expression>
            let newest = try await self.historyStore.samples(
                person: arguments["person"]?.stringValue,
                device: arguments["device"]?.stringValue,
                from: range.lowerBound,
                to: range.upperBound,
                everySeconds: interval,
                limit: limit + 1,
                includePeople: includePeople
            )
            return HistoryReport(
                samples: newest.suffix(limit).map {
                    HistorySample( /* the existing nine fields, unchanged */ )
                },
                truncated: newest.count > limit
            )
   ```

   `<the handler's existing limit expression>`: plan 038 bounds this value. If
   the argument passed as `limit:` still reads exactly
   `max(policy.requestedLimit, 1)` (038 did not change this line), use
   `min(max(policy.requestedLimit, 1), 20_000)` so `limit + 1` cannot
   overflow; `20_000` is the ceiling the sibling tools in this file already
   use. If 038 changed it, use 038's expression as it stands.

3. In the same tool's `inputSchema`, change the `limit` description from
   `"Maximum samples to return."` to
   `"Maximum samples to return. When the range holds more, the newest are returned and truncated is true."`
   Leave `default:` and any `minimum`/`maximum` plan 038 added as they are.

**Verify**: build command → exit 0.

Update the two existing tests that read `location_history` as an array, both
in `iMCPTests/ICloudAuthPlumbingTests.swift` (find with
`grep -n '"location_history"' iMCPTests/ICloudAuthPlumbingTests.swift`; three
hits, the third is inside a `do { ... XCTFail }` block and needs no change).
Add this helper beside the existing `private func jsonArray` (line 990):

```swift
    private func historySamples(_ result: ToolResult) throws -> [[String: Any]] {
        guard case .json(let data) = result,
            let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = report["samples"] as? [[String: Any]]
        else {
            throw CocoaError(.coderReadCorrupt)
        }
        return rows
    }
```

and change `let history = try jsonArray(` to `let history = try historySamples(`
at the two `location_history` call sites only (`location_visits` and
`location_places` keep `jsonArray`).

Add to `LocationTimelineToolTests` in
`iMCPTests/LocationRenewalAndTimelineTests.swift`:

```swift
    func testHistoryKeepsTheNewestSamplesAndSaysWhenItDroppedSome() async throws {
        _ = try await store.record([30.0, 20, 10].map { sample(minutesAgo: $0) })
        let tool = try XCTUnwrap(service().tools.first { $0.name == "location_history" })

        let cut = try object(try await tool(["limit": .int(2)]))
        XCTAssertEqual(cut["truncated"] as? Bool, true)
        let rows = try XCTUnwrap(cut["samples"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        let times = rows.compactMap { $0["time"] as? String }
        XCTAssertEqual(times, times.sorted(), "oldest first within what is returned")
        XCTAssertEqual(times.last, now.addingTimeInterval(-10 * 60).localISO8601)

        let whole = try object(try await tool(["limit": .int(3)]))
        XCTAssertEqual(whole["truncated"] as? Bool, false)
        XCTAssertEqual((whole["samples"] as? [[String: Any]])?.count, 3)
    }
```

(`localISO8601` is the `Date` property the handler itself uses via
`Self.timestamp`; if it is not visible to the test target, drop that one
assertion rather than adding API.)

**Verify**: `Scripts/test.sh --only iMCPTests/LocationTimelineToolTests --only iMCPTests/FindMyPeopleReadinessTests` → all pass.
(`FindMyPeopleReadinessTests` is the class at `ICloudAuthPlumbingTests.swift:550`
that contains the two updated call sites; confirm with
`grep -n "^final class\|location_history" iMCPTests/ICloudAuthPlumbingTests.swift`.)

### Step 3: Validate places in the store, once, for both callers

File: `App/Services/Location/LocationHistoryStore.swift`, function `setPlace(...)`.

Insert as the first statements of the function body (before `let db = try connection()`):

```swift
        guard
            CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)),
            (10 ... 5000).contains(radiusMeters)
        else {
            throw LocationHistoryError.invalidRequest(
                "Latitude must be -90 to 90, longitude -180 to 180, and radiusMeters 10 to 5000."
            )
        }
```

Then, directly after the existing
`if previousName != nil, match == nil { throw ...unknownPlace(target) }` block, add:

```swift
        // A rename must not land on a name another place already has: every
        // lookup is by name, so two rows sharing one are indistinguishable.
        if previousName != nil,
            existing.contains(where: {
                $0.id != match?.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
            })
        {
            throw LocationHistoryError.invalidRequest(
                "A place named \"\(name)\" already exists. Choose another name."
            )
        }
```

The duplicate check is deliberately limited to renames. Without `renaming`,
`match` is found by `name` itself, so no new duplicate can be created; and a
store that already holds two same-named rows from the old bug must still let
the user move one of them.

Put the guard in the store, not the tool handler: the Location window calls
`setPlace` too, and one guard covers both. Do not add a second check in
`Location.swift`.

In `Location.swift`, only the `location_place_set` schema text changes: in the
`radiusMeters` property, change the description to
`"How far from the point still counts as being there, 10 to 5000."`

**Verify**: build command → exit 0.

Add to `LocationHistoryStoreTests` (next to `testRenamingAPlaceThatDoesNotExistSaysSo`):

```swift
    func testAPlaceWithImpossibleNumbersIsRejected() async throws {
        let bad: [(latitude: Double, longitude: Double, radius: Double)] = [
            (999, -73.9, 150), (.nan, -73.9, 150), (40.7, 181, 150),
            (40.7, -73.9, -1), (40.7, -73.9, 1e9), (40.7, -73.9, .nan),
        ]
        for value in bad {
            do {
                _ = try await store.setPlace(
                    name: "Bad",
                    latitude: value.latitude,
                    longitude: value.longitude,
                    radiusMeters: value.radius,
                    source: "manual"
                )
                XCTFail("Expected \(value) to be rejected")
            } catch let error as LocationHistoryError {
                guard case .invalidRequest = error else { return XCTFail("\(error)") }
            }
        }
        let places = try await store.places()
        XCTAssertTrue(places.isEmpty)
    }

    func testRenamingOntoAnotherPlacesNameIsRejected() async throws {
        for name in ["Home", "Office"] {
            _ = try await store.setPlace(
                name: name, latitude: 40.7, longitude: -73.9, radiusMeters: 150, source: "manual"
            )
        }
        do {
            _ = try await store.setPlace(
                name: "home", latitude: 40.7, longitude: -73.9, radiusMeters: 150,
                source: "manual", renaming: "Office"
            )
            XCTFail("Expected the rename to be rejected")
        } catch let error as LocationHistoryError {
            guard case .invalidRequest = error else { return XCTFail("\(error)") }
        }
        let names = try await store.places().map(\.name)
        XCTAssertEqual(names, ["Home", "Office"])
    }
```

If the `.nan` latitude case is not rejected, add `latitude.isFinite, longitude.isFinite,`
as the first two conditions of the guard and re-run.

**Verify**: `Scripts/test.sh --only iMCPTests/LocationHistoryStoreTests` → all pass, including the two new tests.

### Step 4: Ring exactly one device, and not twice in 30 seconds

**4a. One match or an error.** File: `App/Services/Location.swift`.

Add a static helper to `LocationService` (place it directly above
`private func snapshot(locate:)`, in the `// MARK: - Find My` section). It is
internal, not private, so a test can call it:

```swift
    /// The one device of the user's own that `query` names: its id as
    /// `location_devices` reports it, or its name when that is unambiguous.
    static func ownDevice(matching query: String, in devices: [FindMyDevice]) throws -> FindMyDevice {
        let mine = devices.filter { $0.ownerID == nil }
        if let exact = mine.first(where: { $0.id == query }) { return exact }
        let named = mine.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        guard named.count < 2 else {
            throw ToolInputError(
                "More than one of your devices is named \"\(query)\". "
                    + "Pass one of these ids as device: \(named.map(\.id).sorted().joined(separator: ", "))."
            )
        }
        guard let device = named.first else { throw FindMyError.unknownDevice(query) }
        return device
    }
```

In the `location_ring` handler, replace the comment plus the
`guard let device = snapshot.devices.first(where: { ... }) else { throw FindMyError.unknownDevice(name) }`
block (eight lines plus the two-line comment) with:

```swift
                let device = try Self.ownDevice(matching: name, in: snapshot.devices)
```

In the same tool's schema, change the `device` description to
`"The device's name, as location_devices reports it, or its id when two devices share a name."`

Do not touch the tool's `annotations:` block.

**4b. Cooldown.** File: `App/Services/Location/FindMyClient.swift`.

1. Add a case to `enum FindMyError`, after `soundUnavailable(String)`:

   ```swift
       case soundPlayedRecently
   ```

   and its description in the `switch`:

   ```swift
           case .soundPlayedRecently:
               return "That device was asked to play a sound less than 30 seconds ago. Wait before asking again."
   ```

2. In `actor FindMyClient`, add beside the other stored properties
   (after `private var snapshotWaiters`):

   ```swift
       /// When each device was last asked to play a sound. A sound is loud and
       /// in the real world; a client retrying in a loop must not repeat it.
       private var lastSoundAt: [String: Date] = [:]
       static let soundCooldown: TimeInterval = 30
   ```

3. Replace the body of `playSound(deviceID:)` with:

   ```swift
       func playSound(deviceID: String) async throws {
           guard let findMy = account.findMy else { throw FindMyError.notSignedIn }
           let now = Date()
           if let last = lastSoundAt[deviceID], now.timeIntervalSince(last) < Self.soundCooldown {
               throw FindMyError.soundPlayedRecently
           }
           // Claimed before the request: the actor is re-entrant across the
           // await, and two overlapping calls must not both get through.
           lastSoundAt[deviceID] = now
           do {
               _ = try await send(
                   path: "fmipservice/client/web/playSound",
                   base: findMy,
                   body: [
                       "device": deviceID,
                       "subject": "Find My iPhone Alert",
                       "clientContext": ["fmly": true],
                   ]
               )
           } catch {
               lastSoundAt[deviceID] = nil
               throw error
           }
           await noteSuccessfulOperation()
       }
   ```

**Verify**: build command → exit 0.

Add to `FindMyClientTests` in `iMCPTests/ICloudAuthFlowTests.swift` (next to
`testPlaySoundNamesTheDevice`):

```swift
    func testASecondSoundOnTheSameDeviceIsRefusedWithoutARequest() async throws {
        let transport = ScriptedTransport()
        transport.stub("playSound", json: ["status": 200])
        transport.stub("playSound", json: ["status": 200])
        let client = makeClient(transport)

        try await client.playSound(deviceID: "phone")
        do {
            try await client.playSound(deviceID: "phone")
            XCTFail("Expected the cooldown to refuse")
        } catch {
            XCTAssertEqual(error as? FindMyError, .soundPlayedRecently)
        }
        XCTAssertEqual(transport.requests(matching: "playSound").count, 1)

        try await client.playSound(deviceID: "watch")
        XCTAssertEqual(transport.requests(matching: "playSound").count, 2)
    }

    func testAFailedSoundDoesNotStartTheCooldown() async throws {
        let transport = ScriptedTransport()
        transport.stub("playSound", status: 500)
        transport.stub("playSound", json: ["status": 200])
        let client = makeClient(transport)

        do {
            try await client.playSound(deviceID: "phone")
            XCTFail("Expected Apple's rejection")
        } catch {
            XCTAssertEqual(error as? FindMyError, .appleRejectedRequest(status: 500))
        }
        try await client.playSound(deviceID: "phone")
    }

    func testRingingNeedsExactlyOneOfTheUsersOwnDevices() throws {
        func device(_ id: String, _ name: String, owner: String? = nil) -> FindMyDevice {
            FindMyDevice(
                id: id, name: name, model: nil, deviceClass: nil, batteryLevel: nil,
                batteryStatus: nil, isThisDevice: false, ownerID: owner, canPlaySound: true,
                location: nil
            )
        }
        let devices = [
            device("a", "iPhone"), device("b", "iPhone"), device("c", "Watch"),
            device("d", "Tablet", owner: "family-1"),
        ]

        XCTAssertEqual(try LocationService.ownDevice(matching: "watch", in: devices).id, "c")
        XCTAssertEqual(try LocationService.ownDevice(matching: "b", in: devices).id, "b")
        XCTAssertThrowsError(try LocationService.ownDevice(matching: "iPhone", in: devices)) { error in
            let text = (error as? ToolInputError)?.message ?? ""
            XCTAssertTrue(text.contains("a, b"), text)
        }
        XCTAssertThrowsError(try LocationService.ownDevice(matching: "Tablet", in: devices)) { error in
            XCTAssertEqual(error as? FindMyError, .unknownDevice("Tablet"))
        }
    }
```

**Verify**: `Scripts/test.sh --only iMCPTests/FindMyClientTests` → all pass, including the three new tests and the unchanged `testPlaySoundNamesTheDevice`.
**Verify**: `grep -n "snapshot.devices.first(where" App/Services/Location.swift` → no matches.

### Step 5: A fix without a timestamp is not a fix

File: `App/Services/Location/FindMyClient.swift`, `private static func fix(from:)`.

Move the timestamp into the existing guard and delete the `?? 0` line. Result:

```swift
        guard
            let raw,
            let latitude = raw["latitude"] as? Double,
            let longitude = raw["longitude"] as? Double,
            // Apple reports the fix time in milliseconds since the epoch.
            let milliseconds = raw["timeStamp"] as? Double
        else { return nil }
        return FindMyFix(
```

Add to `FindMyClientTests`:

```swift
    func testAFixWithoutATimestampIsNotAFix() async throws {
        let transport = ScriptedTransport()
        transport.stub(
            "initClient",
            json: [
                "serverContext": ["prsId": 1234],
                "content": [
                    ["id": "phone", "name": "Phone", "location": ["latitude": 40.7, "longitude": -74.0]]
                ],
            ]
        )

        let snapshot = try await makeClient(transport).snapshot()

        XCTAssertNil(snapshot.devices.first?.location)
    }
```

**Verify**: `grep -n '?? 0' App/Services/Location/FindMyClient.swift` → no matches.
**Verify**: `Scripts/test.sh --only iMCPTests/FindMyClientTests` → all pass.

### Step 6: Only client-safe text in the health block

First check whether plan 042 has landed a shared helper:
`grep -n "042" plans/README.md`. If its row says DONE, open
`plans/042-actionable-tool-errors.md`, find the helper it adds for "a
`ClientFacingError`'s description, otherwise a generic line", and call that
helper at the two sites below instead of the inline expression. If 042 is not
DONE, use the inline expression exactly as written; define no new function.

1. `App/Services/Location.swift`, in the `catch` block of `now(refresh:)`
   (the line starting `let reason =`): replace `error.localizedDescription`
   with `String(describing: type(of: error))`. Result:

   ```swift
            let reason = (error as? ClientFacingError)?.errorDescription ?? String(describing: type(of: error))
   ```

2. `App/Services/Location/LocationSampler.swift`, in the final `catch` of
   `sampleWeb(client:)`: change only the `status.lastFailure =` line to

   ```swift
            status.lastFailure =
                (error as? ClientFacingError)?.errorDescription ?? String(describing: type(of: error))
   ```

   Leave the `log.error(...)` line below it untouched (plan 042 owns it).

Add to `LocationHistoryStoreTests` in `iMCPTests/ICloudAuthFlowTests.swift`,
next to the existing test that calls `sampler.sampleOnce(webClient:)` (find it
with `grep -n "sampleOnce" iMCPTests/ICloudAuthFlowTests.swift`; if that test
lives in a different class, put the new test in that class):

```swift
    func testASamplingFailureIsRecordedWithoutTheSystemsOwnWords() async throws {
        let account = ICloudAccount(
            dsid: "1234",
            webservices: ["findme": URL(string: "https://p1-fmipweb.icloud.com")!]
        )
        let offline = ScriptedTransport()
        offline.fail("initClient", with: URLError(.notConnectedToInternet))
        let sampler = LocationSampler(store: store, peopleLoader: { [] })
        await sampler.sampleOnce(
            webClient: FindMyClient(transport: offline, account: account, clientID: "client-id")
        )
        let unknown = await sampler.currentStatus().lastFailure
        XCTAssertEqual(unknown, "URLError")

        let rejected = ScriptedTransport()
        rejected.stub("initClient", status: 500)
        await sampler.sampleOnce(
            webClient: FindMyClient(transport: rejected, account: account, clientID: "client-id")
        )
        let facing = await sampler.currentStatus().lastFailure
        XCTAssertEqual(facing, FindMyError.appleRejectedRequest(status: 500).errorDescription)
    }
```

**Verify**: `grep -n "localizedDescription" App/Services/Location.swift` → exactly one match, the `log.debug("Reverse geocoding a fix failed: ...")` line near the end of the file.
**Verify**: `grep -n "lastFailure = error" App/Services/Location/LocationSampler.swift` → no matches.
**Verify**: `Scripts/test.sh --only iMCPTests/LocationHistoryStoreTests --only iMCPTests/LocationHealthMessageTests` → all pass.

### Step 7: Do not remember a failed venue lookup; bound the cache

File: `App/Services/Location/VenueLookup.swift`.

Add beside `static let searchRadius`:

```swift
    /// The cache starts over at this many spots rather than growing for as
    /// long as the app runs.
    static let cacheLimit = 500
```

Replace the body of `venues(latitude:longitude:limit:)` after the cache-hit
line with:

```swift
        // A failed lookup is not an answer. Left uncached, the next request retries.
        guard let found = try? await loader(latitude, longitude, Self.searchRadius) else { return [] }
        let sorted = found.sorted { $0.meters < $1.meters }
        if cache.count >= Self.cacheLimit { cache.removeAll() }
        cache[key] = sorted
        return Array(sorted.prefix(limit))
```

Keep the doc comment above the function; it stays true.

In `iMCPTests/LocationTimelineItemsTests.swift`, extend the existing
`testLookupCachesPerSpotAndSwallowsFailures` by appending, after
`XCTAssertEqual(failed, [])`:

```swift
        _ = await lookup.venues(latitude: 41, longitude: -74)
        XCTAssertEqual(counter.calls, 3, "a failed spot is asked again, not remembered as empty")
```

and add below it:

```swift
    func testTheCacheStartsOverAtItsLimit() async {
        final class Counter: @unchecked Sendable {
            var calls = 0
        }
        let counter = Counter()
        let lookup = VenueLookup { _, _, _ in
            counter.calls += 1
            return []
        }
        for step in 0 ... VenueLookup.cacheLimit {
            _ = await lookup.venues(latitude: Double(step) * 0.01, longitude: 0)
        }
        _ = await lookup.venues(latitude: 0, longitude: 0)
        XCTAssertEqual(counter.calls, VenueLookup.cacheLimit + 2)
    }
```

**Verify**: `grep -n "?? \[\]" App/Services/Location/VenueLookup.swift` → no matches.
**Verify**: `Scripts/test.sh --only iMCPTests/VenueSuggestionTests` → all pass.
(`VenueSuggestionTests`, line 382, is the class holding `testLookupCachesPerSpotAndSwallowsFailures`; confirm with
`grep -n "^final class\|testLookupCachesPerSpotAndSwallowsFailures" iMCPTests/LocationTimelineItemsTests.swift`.)

### Step 8: Format and run the full gate

1. `swift format -i -r .` → exit 0
2. `swift format lint --strict --recursive .` → exit 0
3. `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` → exit 0
4. `Scripts/test.sh` → both suites pass
5. `git status --short` → only files from the in-scope list

## Test plan

All new tests go in existing files (no `project.pbxproj` edits):

| File | Class | New / changed tests |
|------|-------|---------------------|
| `iMCPTests/ICloudAuthFlowTests.swift` | `LocationHistoryStoreTests` | `testAFullLimitKeepsTheNewestSamplesInTimeOrder`, `testAPlaceWithImpossibleNumbersIsRejected`, `testRenamingOntoAnotherPlacesNameIsRejected`, `testASamplingFailureIsRecordedWithoutTheSystemsOwnWords` |
| `iMCPTests/ICloudAuthFlowTests.swift` | `FindMyClientTests` | `testASecondSoundOnTheSameDeviceIsRefusedWithoutARequest`, `testAFailedSoundDoesNotStartTheCooldown`, `testRingingNeedsExactlyOneOfTheUsersOwnDevices`, `testAFixWithoutATimestampIsNotAFix` |
| `iMCPTests/LocationRenewalAndTimelineTests.swift` | `LocationTimelineToolTests` | `testHistoryKeepsTheNewestSamplesAndSaysWhenItDroppedSome` |
| `iMCPTests/ICloudAuthPlumbingTests.swift` | `FindMyPeopleReadinessTests` | two `location_history` call sites switched to the new `historySamples` helper |
| `iMCPTests/LocationTimelineItemsTests.swift` | `VenueSuggestionTests` | extended `testLookupCachesPerSpotAndSwallowsFailures`; new `testTheCacheStartsOverAtItsLimit` |

Structural patterns: tool-level tests follow `LocationTimelineToolTests`
(`testAWholeNumberRadiusIsHonoured`); store tests follow
`testRenamingAPlaceThatDoesNotExistSaysSo`; client tests follow
`testPlaySoundNamesTheDevice`.

Existing tests that must still pass unchanged and guard against regressions in
this plan: `testDownsamplingKeepsOneSamplePerIntervalPerDevice`,
`testVisitsKeepTheLegacyTwentyThousandSampleWorkingSet`,
`testNowFallsBackToTheLastRecordedPositionAndCallsItStale`,
`testVisitsRetriesFailedAddressesAndKeepsNearbyCoordinatesDistinct`,
`testNamingAPlaceTwiceMovesItInsteadOfAddingASecond`.

Verification: `Scripts/test.sh` → all pass, with 10 new test methods.

## Done criteria

ALL must hold:

- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `Scripts/test.sh` passes both suites; the 10 new tests exist and pass
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `grep -n "ORDER BY timestamp ASC" App/Services/Location/LocationHistoryStore.swift` returns no matches
- [ ] `grep -n "snapshot.devices.first(where" App/Services/Location.swift` returns no matches
- [ ] `grep -n '?? 0' App/Services/Location/FindMyClient.swift` returns no matches
- [ ] `grep -c "localizedDescription" App/Services/Location.swift` prints `1`
- [ ] `grep -n "lastFailure = error" App/Services/Location/LocationSampler.swift` returns no matches
- [ ] `grep -n "CLLocationCoordinate2DIsValid" App/Services/Location/LocationHistoryStore.swift` returns one match
- [ ] `git diff --stat main -- App/Views/LocationWindow.swift App/Controllers/ICloudSession.swift App/Models/FetchPolicy.swift README.md` is empty
- [ ] No files outside the in-scope list are modified (`git status --short`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plans 037 or 038 are not merged into the branch you started from
  (`grep -n "| 037\|| 038" plans/README.md` does not show DONE for both).
- `samples(...)` in `LocationHistoryStore.swift` no longer has the shape quoted
  in "Defect 1" (for example, someone already added a SQL `LIMIT` or changed
  the return type).
- A caller of `samples(...)` turns out to depend on receiving the *oldest*
  rows when truncated, or any existing test fails after Step 1 other than by
  the array-to-object change handled in Step 2.
- After Step 2, any test other than the two named `location_history` call
  sites fails because of the response shape. That means another consumer of
  the array shape exists that this plan did not find.
- Step 3's guard rejects a value that an existing test or the Location window
  legitimately passes (the window's slider is `30 ... 400`; if you find a
  caller outside `10 ... 5000`, report it rather than widening the range).
- `FindMyError` has gained another exhaustive `switch` somewhere, so adding
  `soundPlayedRecently` breaks a file outside the in-scope list.
- Plan 042 is DONE but you cannot identify a single helper with the contract
  described in Step 6.
- Any step's verification fails twice after a reasonable fix attempt.
- A fix appears to require touching an out-of-scope file.
- Anything asks for an Apple ID password, a 2FA code, a Find My People
  bootstrap, or a System Settings privacy change. Those are HUMAN STEPS; no
  step of this plan needs one, and no test in it contacts Apple.

## Maintenance notes

- **Response-shape change.** `location_history` now returns
  `{"samples": [...], "truncated": Bool}` instead of an array. `README.md`
  does not describe the old shape, so nothing there is wrong, but plan 053
  (docs) should mention `truncated`. `location_visits` deliberately keeps its
  array shape (the README promises it) and has no truncation flag; with a
  20,000-row working set it now loses the *oldest* rows rather than the
  newest when a range exceeds that.
- **Net size.** This plan adds guards, so it is not net-negative: roughly +45
  source lines and +170 test lines. The subtraction is in what was not added:
  no new error type, no new file, no SQL `LIMIT` binding, validation in one
  place for two callers, and the geocode-dedupe lead dropped as already done.
- **Downsampling now keeps the newest sample per bucket**, not the oldest. The
  count per bucket is unchanged.
- **Cooldown state lives on the `FindMyClient` instance.** `ICloudSession`
  builds a new client when it adopts a renewed account, which resets the
  cooldown. That is acceptable (a renewal is rare) but it is why the limit is
  not a hard guarantee.
- **Type-name fallback is terse.** A network failure now reads
  `Find My did not answer (URLError)` and `Last failure: URLError` rather than
  the system sentence. If plan 042 introduces a friendlier generic line, switch
  the two sites in Step 6 to it.
- **For plan 038's owner**: three integer arguments in `Location.swift` are
  multiplied without bounds and trap on a huge value —
  `intervalMinutes` (`max($0, 0) * 60`) in `location_history`, and
  `minimumMinutes` (`max(... ?? 10, 0) * 60`) in `location_visits` and
  `location_timeline`. They were left alone here because 038 owns integer
  argument parsing.
- **For plan 042's owner**: `LocationSampler.swift`'s
  `log.error("Location sampling failed: ... privacy: .public)` line is
  untouched and still logs the raw description.
- **Pre-existing duplicate place names** are not repaired; Step 3 only stops
  new ones. Plan 054's delete tool is the way to remove one.
- **Reviewer focus**: the `limit + 1` expression in Step 2 (must not be able
  to overflow), and that `LocationWindow.swift` behaves the same with the
  store returning newest-first truncation (it should only ever improve).
- Do not run `Scripts/install-local.sh run` as part of this plan; install only
  if the operator asks.
