# Plan 047: The Location window reloads only when history changes, and a cancelled sampler tick reports nothing

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- App/Views/LocationWindow.swift App/Services/Location/LocationSampler.swift App/Views/SettingsView.swift App/Services/Location/LocationHistoryStore.swift iMCPTests/LocationTimelineItemsTests.swift iMCPTests/ICloudAuthFlowTests.swift`
> Plans 037 and 040 land before this one and are expected to touch some of
> these files (see "Depends on"). For every file that changed, compare the
> "Current state" excerpts against the live code before proceeding. Shifted
> line numbers are fine; a function whose shape no longer matches its excerpt
> is a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/037-isolate-tests-from-real-state.md, plans/040-location-tool-correctness.md
- **Category**: perf, bug
- **Planned at**: commit `8165d29`, 2026-10-12

## Why this matters

While the Location window is open it re-reads a month of location history
twice and re-runs visit inference twice, on the main actor, every 60 seconds,
although the sampler writes at most one new fix every 600 seconds. Each pass
reassigns every published property, so the map redraws each minute, and the
map view recomputes the track geometry (filter, sort, smoothing, distances)
twice per redraw. Reloads started by the timer and by buttons overlap and can
finish out of order, leaving the sidebar showing data for a range the user has
already left. Separately, when the sampler is restarted or stopped while a tick
is in flight, the cancelled tick writes a `CancellationError` description into
`lastFailure`, which the window shows in red and the location tools report to
MCP clients. After this plan: a cheap once-a-minute tick refreshes the status
strip and triggers a full reload only when the store actually changed; only one
reload is ever live; a cancelled sampler tick writes nothing.

## Current state

All excerpts are from commit `8165d29`.

### Files

- `App/Views/LocationWindow.swift` (1264 lines) — the Location window:
  `LocationWindowController`, `LocationWindowPresenter`, `LocationWindowModel`
  (the `ObservableObject`), and the SwiftUI views (`LocationMapView`,
  `LocationSidebar`, `AddPlaceSheet`, ...).
- `App/Views/LocationTimelineItems.swift` — pure helpers the map uses
  (`solidSegments`, `colourRuns`, `gapSpans`, `trackSpan`). Read only; not
  modified.
- `App/Services/Location/LocationSampler.swift` (266 lines) — the actor that
  polls Find My every 600 s and writes to the history store.
- `App/Services/Location/LocationHistoryStore.swift` — the SQLite store actor.
  Read only; this plan calls its existing `summary()`.
- `App/Views/SettingsView.swift` — `LocationHistorySection` (line 774) and the
  Purge button in `FindMyPeopleSettingsSection` (line 700).
- `iMCPTests/LocationTimelineItemsTests.swift` — holds `LocationWindowModelTests`
  (line 243 and three extensions).
- `iMCPTests/ICloudAuthFlowTests.swift` — holds the sampler tests inside
  `LocationHistoryStoreTests` (class starts line 1537; sampler tests at
  2030-2146).

### The 60 s full reload (`LocationWindow.swift`)

```swift
// :41-42  — the comment is false: reopening calls startRefreshing(), which reloads
/// Shows the Location window from the menu, keeping one controller and one
/// model alive so reopening it does not re-read a month of history.

// :46
    private static let model = LocationWindowModel()

// :117-118
    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: Duration

// :126 (init parameter) and :134
        refreshInterval: Duration = .seconds(60)
        self.selectedDay = Calendar.current.startOfDay(for: Date())

// :164-182
    func startRefreshing() {
        guard refreshTask == nil else { return }
        let interval = refreshInterval
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reload()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }
```

`reload()` (`:184-249`) reads the visible range with `limit: 20_000`
(`:188-195`), reads named places (`:197`), runs `VisitInference.timeline`
(`:202-208`), reads the last 30 days with `limit: 20_000` (`:212-220`), runs
`VisitInference.timeline` a second time (`:224-230`), assigns six published
properties (`:233-238`), calls `suggestVenues()` (`:239`), then computes and
assigns `health` (`:246-248`). `LocationWindowModel` is `@MainActor`, so both
inference passes run on the main thread.

`selectedDay` is set once in `init` (`:134`) on a model that lives for the
whole process (`:46`), so a window reopened the next day still shows
yesterday.

`VisitInference.timeline` depends on the `now` it is given (a trailing gap and
"ongoing" versus "ended" both use it; `App/Services/Location/VisitInference.swift:291-314`),
so the timeline can go stale even when no sample arrives. That is why Step 4
keeps a slow fallback reload instead of reloading only on store changes.

### Overlapping reloads (`LocationWindow.swift`)

Four places start an untracked reload next to the timer:

```swift
// :148-162
    func shiftDay(by days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: selectedDay) else { return }
        selectedDay = min(next, Calendar.current.startOfDay(for: Date()))
        Task { await reload() }
    }

    func showToday() {
        selectedDay = Calendar.current.startOfDay(for: Date())
        Task { await reload() }
    }

    func setDays(_ days: Int) {
        daysShown = days
        Task { await reload() }
    }

// :523-525 (the toolbar reload button)
            Button {
                Task { await model.reload() }
            } label: {
```

`addPlace` (`:402`), `deletePlace` (`:408`) and `name` (`:430`) also
`await reload()`. Nothing stops two reloads from interleaving. The tail of
`suggestVenues()` assigns whatever it computed, for whichever `items` it
started with:

```swift
// :311-323
            let key = String(format: "%.4f,%.4f", visit.latitude, visit.longitude)
            if addressCache[key] == nil,
                let street = await addressLoader(visit.latitude, visit.longitude)
            {
                addressCache[key] = street
            }
            if let street = addressCache[key] { streets[item.id] = street }
        }
        guard !Task.isCancelled else { return }
        suggestions = found
        venues = nearby
        addresses = streets
    }
```

`reload()` already checks cancellation after every `await` before it assigns
(`:196`, `:198`, `:222`, `:245`, `:247`, and inside `suggestVenues` at `:303`,
`:306`, `:319`). Nothing ever cancels it, except the timer being stopped. Two
spots are not guarded: the generic `catch` at `:242-244` assigns `loadError`
even when cancelled, and `:315` writes `addressCache` after an `await` without
a check.

### Track geometry computed in `body` (`LocationWindow.swift`)

```swift
// :85
    @Published private(set) var trackSamples: [LocationSample] = []
// :235
            self.trackSamples = subject.filter { $0.deviceID == device }

// :653-667 (inside LocationMapView)
    private var segments: [LocationTimelineItems.Segment] {
        LocationTimelineItems.solidSegments(samples: model.trackSamples)
    }

    private var trackSpan: ClosedRange<Date>? {
        LocationTimelineItems.trackSpan(of: segments)
    }

    private var colourRuns: [LocationTimelineItems.ColourRun] {
        LocationTimelineItems.colourRuns(segments: segments)
    }

    private var gapSpans: [(gap: CoverageGap, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D)] {
        LocationTimelineItems.gapSpans(samples: model.trackSamples, gaps: model.timeline?.gaps ?? [])
    }
```

`body` uses `colourRuns` (`:546`), `gapSpans` (`:553`) and `trackSpan`
(`:637`). `segments` is therefore evaluated twice per `body` pass (a filter
plus a sort each time), `colourRuns` smooths every segment and sums
`CLLocation` distances (`LocationTimelineItems.swift:184-220`), and `gapSpans`
sorts again (`LocationTimelineItems.swift:264`). `trackSamples` has no other
reader in `App/` or `iMCPTests/`.

### `AddPlaceSheet` (`LocationWindow.swift:1077-1090, 1170-1173`)

```swift
            if chosen == nil {
                List(results, id: \.self, selection: $chosen) { item in
                    ...
                }
                .frame(height: 180)
                .onChange(of: chosen) { _, item in
                    guard let item else { return }
                    name = item.name ?? ""
                    Task { await snapToHistory(item) }
                }
            } else if let chosen {
```

```swift
    private func snapToHistory(_ item: MKMapItem) async {
        let coordinate = item.placemark.coordinate
        snap = await model.snap(near: coordinate.latitude, longitude: coordinate.longitude)
    }
```

The `.onChange(of: chosen)` is attached to the `List` that the same change
removes from the hierarchy, so whether it fires depends on SwiftUI's teardown
order (low confidence that it misfires today; cheap to make certain). The
untracked `Task` can also assign `snap` after the user pressed "Change"
(`:1096-1099`, which sets `chosen = nil; snap = nil`).

### Sampler (`LocationSampler.swift`)

```swift
// :63-82
    func start(webClient: FindMyClient?) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        task?.cancel()
        // A new client has no server context yet, and Apple ignores a locate
        // request without one, so the first tick has to list devices anyway.
        trackedPhone = nil
        status.isRunning = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleOnce(webClient: webClient)
                ...

// :96-100
    func stop() {
        task?.cancel()
        task = nil
        status.isRunning = false
    }
```

`start` and `stop` cancel the loop task but do not wait for it. The cancelled
task is usually suspended inside `sampleWeb` (`:153-202`), in a network call.
When that call returns or throws, `sampleWeb` carries on writing actor state:

```swift
// :160-170
                let cached = try await client.snapshot(locate: false)
                guard let phone = Self.phoneToTrack(in: cached) else {
                    trackedPhone = nil
                    log.error("No current-user iPhone is available for location history")
                    status.lastFailure = "No iPhone of the signed-in user is visible in Find My."
                    return
                }
                phoneID = phone.id
                trackedPhone = (phone.id, now())
            }
            let snapshot = try await client.snapshot(locate: true, selectedDeviceID: phoneID)

// :176-181
            let written = try await store.record(Self.samples(from: snapshot))
            status.lastSuccessAt = Date()
            status.lastFailure = nil
            log.debug("Recorded \(written) new iPhone location samples")
        } catch ICloudAuthError.trustExpired {
            status.lastFailure = "The iCloud session was rejected; renewing it."

// :195-201
            Task.detached { _ = await ICloudSession.shared.refreshSession() }
        } catch {
            // A sampler that stopped on the first network hiccup would leave a
            // silent hole in the history. The next tick tries again.
            status.lastFailure = error.localizedDescription
            log.error("Location sampling failed: \(error.localizedDescription, privacy: .public)")
        }
```

Consequences, all confirmed by reading the code:

- `FindMyClient.snapshot` begins with `try Task.checkCancellation()`
  (`App/Services/Location/FindMyClient.swift:138`), so a cancelled tick throws
  `CancellationError`, which lands in the generic `catch` and sets
  `lastFailure` to the cancellation description. The window shows it in red
  (`LocationWindow.swift:292`, `failure: sampler.lastFailure ?? session.failure`
  — it also hides the session's own failure) and the tools report it
  (`App/Services/Location.swift:1320` and `:1352`).
- The old tick can set `trackedPhone` from the *old* client after `start` reset
  it to `nil` for the new one, defeating the comment at `:68-69`.
- `stop()` leaves `status.lastFailure` set forever on a sampler that is no
  longer running.

Plan 040 changes the text assigned at `:199-200` (it sanitises the error). That
edit and this plan's guard do not conflict: keep whatever 040 put on those two
lines and add the guard above them.

**Lead rejected, do not act on it**: `reconciledGeneration` (`:47`) is read
only by `testSamplerIgnoresStaleDesiredStateReconciliation`
(`iMCPTests/ICloudAuthFlowTests.swift:2084-2090`). It stays. `start()` returns
immediately under XCTest (`:64-66`), so `isRunning` cannot observe the
generation guard at `:87`; that accessor is the only way the test can see it,
and deleting it deletes the only coverage of the ordering rule.

### Settings (`SettingsView.swift`)

```swift
// :826-840 (LocationHistorySection)
        .task {
            await load()
        }
        .alert("Delete Location History", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await LocationHistoryStore.shared.deleteSamples()
                    } catch {
                        failure = error.localizedDescription
                    }
                    await load()
                }
            }

// :885-892
    private func load() async {
        do {
            summary = try await LocationHistoryStore.shared.summary()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
```

A failed delete sets `failure`, then `load()` succeeds and sets
`failure = nil`: the user never sees the error. The second alert
(`:846-857`, "Delete Friend Location History") is a copy of the same block
calling `deletePeopleSamples()`.

The summary is loaded once per appearance (`:826-828`). The Purge button in the
sibling section deletes friend history (`:702-712`) without telling this
section, and samples recorded in the background while Settings is open never
show up.

```swift
// :424-426 (GeneralSettingsView.body)
            FindMyPeopleSettingsSection()

            LocationHistorySection()
// :450
        .formStyle(.grouped)

// :702-713
            Button("Purge", role: .destructive) {
                run {
                    try await FindMyPeopleReadiness.shared.purge(
                        deletePeopleHistory: {
                            try await LocationHistoryStore.shared.deletePeopleSamples()
                        },
                        clearPreparedHandoff: {
                            await FindMyPeopleBootstrap.shared.clearPreparedHandoff()
                        }
                    )
                }
            }

// :738-752 — the exemplar helper shape to copy
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        working = true
        message = nil
        Task { @MainActor in
            do {
                try await operation()
            ...
```

`PermissionsSettingsView` already refreshes on activation; copy its form
(`:120-124`):

```swift
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refresh()
        }
```

### The store call this plan reuses (`LocationHistoryStore.swift:120-126, 328`)

```swift
struct LocationHistorySummary: Sendable, Equatable {
    let sampleCount: Int
    let peopleSampleCount: Int
    let oldest: Date?
    let newest: Date?
    let placeCount: Int
}
...
    func summary() throws -> LocationHistorySummary {
```

One aggregate query plus a place count. It changes whenever a sample is
recorded, pruned or deleted, or a place is added or removed, which is exactly
"the window's data is stale". No new store API is needed.

### Conventions that apply

- Swift 6 strict concurrency, warnings are errors. Local Xcode is 27 beta, CI
  is Xcode 26.0. Xcode 27 adds `ImplicitStrongCapture`: when a `Task { ... }`
  inside a class method uses `self`, write the capture explicitly
  (`Task { [self] in ... }` for a deliberate strong capture, `[weak self]` on
  the outer escaping closure otherwise).
- Every member of a SwiftUI `View` is `@MainActor`-isolated.
  `LocationWindowModel` is `@MainActor`. `LocationSampler` and
  `LocationHistoryStore` are actors.
- Owner preference, binding: fix by subtraction and consolidation. Do not add a
  type, a protocol, or a store method in this plan.
- No new files. All tests go into the two existing test files named above, so
  `iMCP.xcodeproj/project.pbxproj` is not touched.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| Window tests | `Scripts/test.sh --only iMCPTests/LocationWindowModelTests` | all pass |
| Sampler tests | `Scripts/test.sh --only iMCPTests/LocationHistoryStoreTests` | all pass |
| Map helper tests | `Scripts/test.sh --only iMCPTests/LocationTimelineItemsTests` | all pass |
| All tests | `Scripts/test.sh` | all pass |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

`Scripts/test.sh --only SPEC` passes `-only-testing:SPEC` to `xcodebuild` and
implies the app suite; it is repeatable. Never run
`xcodebuild test -scheme iMCP` directly: the always-on watchdog relaunches the
installed app and breaks the test host. Never `launchctl bootout` the always-on
agent. If `xcodebuild` reports "failed with exit code 0 but produced no further
output", run it again.

## Scope

**In scope** (the only files you should modify):

- `App/Views/LocationWindow.swift`
- `App/Services/Location/LocationSampler.swift`
- `App/Views/SettingsView.swift` — only `LocationHistorySection`, the two lines
  that construct the sections in `GeneralSettingsView.body`, one modifier after
  `.formStyle(.grouped)` in `GeneralSettingsView`, and the Purge button's
  closure in `FindMyPeopleSettingsSection`
- `iMCPTests/LocationTimelineItemsTests.swift`
- `iMCPTests/ICloudAuthFlowTests.swift` — additions inside
  `LocationHistoryStoreTests` only
- `plans/README.md` — this plan's status row only

**Out of scope** (do NOT touch, even though they look related):

- `App/Services/Location.swift` tool handlers, `LocationHistoryStore.swift`,
  `FindMyClient.swift`, `VenueLookup.swift` — plan 040.
- The wording of error text shown to users or clients
  (`error.localizedDescription` anywhere) — plans 040 and 042.
- `LocationWindowModel.snap(near:)` (`LocationWindow.swift:363-383`). It reads
  the month again, but only when the user picks a search result. Caching the
  month for it would add state for no measurable gain.
- Moving visit inference off the main actor. After this plan it runs at most
  once per sampler interval; a background pipeline is not justified.
- `reconciledGeneration` and its test (see "Lead rejected" above).
- `ICloudSession.syncSampler` (`App/Controllers/ICloudSession.swift:779-791`)
  and anything else in iCloud sign-in — plan 045.
- "Clear Key" and the rest of `FindMyPeopleSettingsSection` — plan 046. Other
  Settings sections — plan 048.
- Splitting `Location.swift` or `LocationWindow.swift` into more files —
  considered and rejected.
- `iMCP.xcodeproj/project.pbxproj`.

## Git workflow

- Start from an up-to-date `main` that already contains plans 037 and 040.
- Branch: `advisor/047-location-window-sampler`
- One commit per step. Conventional commits, matching the log, for example
  `fix: bring Settings forward from the menu; stay quiet on relaunch` and
  `perf(location): locate the tracked phone without listing devices every tick`.
  Suggested messages are given per step.
- Do NOT push or open a PR unless the operator instructed it. `origin`
  (`cyberpapiii/iMCP`) is the only writable remote; `upstream` (`mattt/iMCP`)
  must never receive a push or a PR.

## Steps

### Step 1: A cancelled sampler tick writes nothing; `stop()` clears the failure

File: `App/Services/Location/LocationSampler.swift`.

1. In `sampleWeb(client:)`, add `try Task.checkCancellation()` on the line
   after each of the two `client.snapshot` awaits:

   ```swift
                   let cached = try await client.snapshot(locate: false)
                   try Task.checkCancellation()
                   guard let phone = Self.phoneToTrack(in: cached) else {
   ...
               let snapshot = try await client.snapshot(locate: true, selectedDeviceID: phoneID)
               // `start` and `stop` cancel this task without waiting for it. A
               // superseded tick discards what it read, as the People path does.
               try Task.checkCancellation()
   ```

2. Make both `catch` clauses ignore a cancelled tick:

   ```swift
           } catch ICloudAuthError.trustExpired where !Task.isCancelled {
               status.lastFailure = "The iCloud session was rejected; renewing it."
               ... (unchanged)
           } catch {
               // A cancelled tick has nothing to report: `start` or `stop`
               // already owns the status.
               guard !Task.isCancelled else { return }
               ... (the two existing lines, unchanged; plan 040 may have reworded them)
           }
   ```

3. In `stop()`, add `status.lastFailure = nil` after `status.isRunning = false`.

Do not add a generation counter and do not make `start`/`stop` `async`. The
loop task's own cancellation flag is the signal: `sampleOnce` runs inside that
task, and tests call `sampleOnce` from an uncancelled task.

4. Add two tests inside `final class LocationHistoryStoreTests` in
   `iMCPTests/ICloudAuthFlowTests.swift`, directly after
   `testSamplerIgnoresStaleDesiredStateReconciliation` (ends near line 2090).
   Build the `FindMyClient` exactly as
   `testSamplerReusesThePhoneItChoseInsteadOfListingDevicesEveryTick`
   (`:2092-2120`) does, but with a transport that fails:

   ```swift
       private func failingClient() -> FindMyClient {
           let transport = ScriptedTransport()
           for _ in 0 ..< 4 {
               transport.fail("initClient", with: URLError(.notConnectedToInternet))
           }
           return FindMyClient(
               transport: transport,
               account: ICloudAccount(
                   dsid: "1234",
                   webservices: ["findme": URL(string: "https://p1-fmipweb.icloud.com")!]
               ),
               clientID: "client-id"
           )
       }

       func testStoppingTheSamplerClearsItsLastFailure() async {
           let sampler = LocationSampler(store: store, peopleLoader: { [] })
           await sampler.sampleOnce(webClient: failingClient())
           let failed = await sampler.currentStatus()
           XCTAssertNotNil(failed.lastFailure)

           await sampler.stop()
           let stopped = await sampler.currentStatus()
           XCTAssertNil(stopped.lastFailure)
           XCTAssertFalse(stopped.isRunning)
       }

       func testACancelledTickLeavesTheStatusAlone() async {
           let sampler = LocationSampler(store: store, peopleLoader: { [] })
           let client = failingClient()
           let tick = Task {
               withUnsafeCurrentTask { $0?.cancel() }
               await sampler.sampleOnce(webClient: client)
           }
           await tick.value
           let status = await sampler.currentStatus()
           XCTAssertNil(status.lastFailure, "A superseded tick must not report its own cancellation")
       }
   ```

   Before the production edit, the second test fails because
   `FindMyClient.snapshot` throws `CancellationError` and the generic `catch`
   records it. Write the tests first and confirm that failure if you want proof.

**Verify**: `Scripts/test.sh --only iMCPTests/LocationHistoryStoreTests` → all
pass, including the two new tests and the unchanged
`testSamplerReusesThePhoneItChoseInsteadOfListingDevicesEveryTick`.

Commit: `fix(location): a cancelled sampler tick no longer reports a failure`

### Step 2: One reload at a time

File: `App/Views/LocationWindow.swift`, `LocationWindowModel`.

1. Add a stored property next to `refreshTask` (`:117`):

   ```swift
       private var reloadTask: Task<Void, Never>?
   ```

2. Rename the existing `func reload() async` (`:184`) to
   `private func load() async`, body unchanged, and add above it:

   ```swift
       /// Reloads the window, replacing any reload still in flight. An older
       /// reload can then never finish last and overwrite a newer range.
       func reload() async {
           reloadTask?.cancel()
           let task = Task { [self] in await load() }
           reloadTask = task
           await task.value
       }
   ```

   Every existing caller keeps calling `reload()`; none of them changes. The
   cancelled `load()` returns at its next existing cancellation check without
   assigning anything.

3. Close the two unguarded spots in `load()` / `suggestVenues()`:

   ```swift
           } catch is CancellationError {
               return
           } catch {
               guard !Task.isCancelled else { return }
               self.loadError = error.localizedDescription
           }
   ```

   ```swift
               let key = String(format: "%.4f,%.4f", visit.latitude, visit.longitude)
               if addressCache[key] == nil {
                   let street = await addressLoader(visit.latitude, visit.longitude)
                   guard !Task.isCancelled else { return }
                   addressCache[key] = street
               }
               if let street = addressCache[key] { streets[item.id] = street }
   ```

   (Assigning `nil` to a dictionary key is a no-op removal, so a failed lookup
   is still retried next time, as today.)

4. Add this test to `iMCPTests/LocationTimelineItemsTests.swift`, after the
   `WindowRefreshCounter` extension (ends line 511). Model the fixture on
   `testReloadListsTodaysStaysAndNamingWritesThePlaceTheToolsRead` (`:245-281`),
   which is known to produce exactly one unnamed stay.

   ```swift
   /// The first address lookup waits until released; later ones answer at once.
   private actor AddressGate {
       private var calls = 0
       private var waiter: CheckedContinuation<Void, Never>?
       var isOccupied: Bool { waiter != nil }

       func address() async -> String? {
           calls += 1
           guard calls == 1 else { return "Second St" }
           await withCheckedContinuation { waiter = $0 }
           return "First St"
       }

       func release() {
           waiter?.resume()
           waiter = nil
       }
   }

   extension LocationWindowModelTests {
       @MainActor
       func testANewerReloadReplacesTheOneInFlight() async throws {
           let directory = FileManager.default.temporaryDirectory
               .appendingPathComponent(UUID().uuidString, isDirectory: true)
           defer { try? FileManager.default.removeItem(at: directory) }
           let now = Date()
           let store = LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite"), now: { now })
           var samples: [LocationSample] = []
           for minutesAgo in stride(from: 60, through: 5, by: -10) {
               samples.append(
                   LocationSample(
                       deviceID: "phone",
                       deviceName: "Rob's iPhone",
                       personName: "Rob",
                       isMe: true,
                       latitude: 40.7464,
                       longitude: -74.9445,
                       accuracyMeters: 20,
                       positionType: "Wifi",
                       timestamp: now.addingTimeInterval(-Double(minutesAgo) * 60)
                   )
               )
           }
           _ = try await store.record(samples)
           let (storage, _) = storageInMemory()
           let session = ICloudSession(transport: ScriptedTransport(), storage: storage)
           let gate = AddressGate()
           let model = LocationWindowModel(
               store: store,
               venueLookup: VenueLookup { _, _, _ in [] },
               addressLoader: { _, _ in await gate.address() },
               session: { session },
               samplerStatus: { LocationSamplerStatus(isRunning: true) }
           )

           let first = Task { await model.reload() }
           while !(await gate.isOccupied) { await Task.yield() }
           await model.reload()
           XCTAssertEqual(Array(model.addresses.values), ["Second St"])

           await gate.release()
           await first.value
           XCTAssertEqual(
               Array(model.addresses.values),
               ["Second St"],
               "A reload that was replaced must not publish when it finally returns"
           )
       }
   }
   ```

**Verify**: `Scripts/test.sh --only iMCPTests/LocationWindowModelTests` → all
pass, including the new test and the four existing ones.

Commit: `fix(location): keep one Location window reload live at a time`

### Step 3: Compute the track geometry once per reload

File: `App/Views/LocationWindow.swift`.

1. In `LocationWindowModel`, replace the `trackSamples` property (`:85`) with:

   ```swift
       /// What the map draws for the track. Computed once per reload, not in
       /// the view's `body`, which runs on every published change.
       @Published private(set) var colourRuns: [LocationTimelineItems.ColourRun] = []
       @Published private(set) var gapSpans:
           [(gap: CoverageGap, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D)] = []
       @Published private(set) var trackSpan: ClosedRange<Date>?
   ```

2. In `load()`, replace the `self.trackSamples = ...` line (`:235`) with:

   ```swift
               let track = subject.filter { $0.deviceID == device }
               let segments = LocationTimelineItems.solidSegments(samples: track)
               self.colourRuns = LocationTimelineItems.colourRuns(segments: segments)
               self.gapSpans = LocationTimelineItems.gapSpans(samples: track, gaps: timeline.gaps)
               self.trackSpan = LocationTimelineItems.trackSpan(of: segments)
   ```

3. In `LocationMapView`, delete the four computed properties `segments`,
   `trackSpan`, `colourRuns`, `gapSpans` (`:653-667`) and point their three uses
   at the model: `colourRuns` → `model.colourRuns` (`:546`), `gapSpans` →
   `model.gapSpans` (`:553`), `trackSpan` → `model.trackSpan` (`:637`). Leave
   the `visits` computed property (`:675-684`) alone: it is a cheap map over
   `model.items`.

**Verify**:
- `grep -n "trackSamples" App iMCPTests -r` → no matches.
- `grep -n "LocationTimelineItems.solidSegments\|LocationTimelineItems.colourRuns\|LocationTimelineItems.gapSpans" App/Views/LocationWindow.swift`
  → exactly three lines, all inside `load()`.
- `Scripts/test.sh --only iMCPTests/LocationWindowModelTests --only iMCPTests/LocationTimelineItemsTests`
  → all pass.

Commit: `perf(location): compute the map track once per reload, not per render`

### Step 4: Tick cheaply; reload only when the store changed

File: `App/Views/LocationWindow.swift`, `LocationWindowModel`.

1. Add two stored properties next to `reloadTask`:

   ```swift
       private var loadedSummary: LocationHistorySummary?
       private var loadedAt = Date.distantPast
   ```

2. Replace `startRefreshing()` (`:164-177`) with the following. The loop is
   unchanged except that it calls `tick()`; the two new lines before it make
   every open start on today with a guaranteed reload.

   ```swift
       func startRefreshing() {
           guard refreshTask == nil else { return }
           // The model outlives the window, so an open days later must not
           // resume on the day it was closed on.
           selectedDay = Calendar.current.startOfDay(for: Date())
           loadedAt = .distantPast
           let interval = refreshInterval
           refreshTask = Task { [weak self] in
               while !Task.isCancelled {
                   await self?.tick()
                   do {
                       try await Task.sleep(for: interval)
                   } catch {
                       return
                   }
               }
           }
       }

       /// One refresh tick. The sampler writes every ten minutes, so most
       /// ticks only re-age the status strip. The full reload runs when the
       /// store changed, or when the last one is a sampler interval old (the
       /// timeline's trailing gap depends on the clock, not only on samples).
       private func tick() async {
           let now = Date()
           let summary = try? await store.summary()
           if summary != loadedSummary || now.timeIntervalSince(loadedAt) >= LocationSampler.intervalSeconds {
               loadedSummary = summary
               loadedAt = now
               await reload()
           } else {
               let health = await currentHealth(now: now)
               guard !Task.isCancelled, health != self.health else { return }
               self.health = health
           }
       }
   ```

   `stopRefreshing()` is unchanged. `refreshInterval` stays an `init`
   parameter with its 60 s default: it is now the tick, and
   `testWindowRefreshStopsWhenClosedAndRestartsOnReopen` relies on injecting
   it.

3. Replace the false comment at `:41-42` with:

   ```swift
   /// Shows the Location window from the menu. One controller and one model
   /// live for the whole process, so the window keeps its frame and its
   /// address cache; the history itself is re-read each time it opens.
   ```

4. Add this test to `iMCPTests/LocationTimelineItemsTests.swift`, after the test
   added in Step 2:

   ```swift
   extension LocationWindowModelTests {
       @MainActor
       func testTicksReloadOnlyWhenTheStoreChanges() async throws {
           let directory = FileManager.default.temporaryDirectory
               .appendingPathComponent(UUID().uuidString, isDirectory: true)
           defer { try? FileManager.default.removeItem(at: directory) }
           let now = Date()
           let store = LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite"), now: { now })
           func fix(minutesAgo: Double) -> LocationSample {
               LocationSample(
                   deviceID: "phone",
                   deviceName: "Rob's iPhone",
                   personName: "Rob",
                   isMe: true,
                   latitude: 40.7464,
                   longitude: -74.9445,
                   accuracyMeters: 20,
                   positionType: "Wifi",
                   timestamp: now.addingTimeInterval(-minutesAgo * 60)
               )
           }
           _ = try await store.record([fix(minutesAgo: 30), fix(minutesAgo: 20)])
           let (storage, _) = storageInMemory()
           let session = ICloudSession(transport: ScriptedTransport(), storage: storage)
           let model = LocationWindowModel(
               store: store,
               venueLookup: VenueLookup { _, _, _ in [] },
               addressLoader: { _, _ in nil },
               session: { session },
               samplerStatus: { LocationSamplerStatus(isRunning: true) },
               refreshInterval: .milliseconds(10)
           )
           model.startRefreshing()
           defer { model.stopRefreshing() }
           for _ in 0 ..< 200 {
               if model.timeline != nil { break }
               try await Task.sleep(for: .milliseconds(10))
           }
           let shown = try XCTUnwrap(model.timeline?.range)

           // Only a reload re-reads `daysShown`, so the published range is
           // the tell for whether one ran.
           model.daysShown = 1
           try await Task.sleep(for: .milliseconds(150))
           XCTAssertEqual(model.timeline?.range, shown, "Ticks over an unchanged store must not reload")

           _ = try await store.record([fix(minutesAgo: 1)])
           for _ in 0 ..< 200 {
               if model.timeline?.range != shown { break }
               try await Task.sleep(for: .milliseconds(10))
           }
           XCTAssertNotEqual(model.timeline?.range, shown, "A new sample must trigger a reload")
           XCTAssertEqual(
               model.latest?.at.timeIntervalSince1970 ?? 0,
               now.addingTimeInterval(-60).timeIntervalSince1970,
               accuracy: 0.001
           )
       }

       @MainActor
       func testReopeningTheWindowReturnsToToday() {
           let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
           defer { try? FileManager.default.removeItem(at: directory) }
           let (storage, _) = storageInMemory()
           let session = ICloudSession(transport: ScriptedTransport(), storage: storage)
           let model = LocationWindowModel(
               store: LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite")),
               session: { session },
               samplerStatus: { LocationSamplerStatus(isRunning: false) }
           )
           model.shiftDay(by: -3)
           XCTAssertFalse(model.isToday)
           model.startRefreshing()
           XCTAssertTrue(model.isToday)
           model.stopRefreshing()
       }
   }
   ```

   Against the old code the first test fails at the first `XCTAssertEqual`
   (every 10 ms tick reloaded) and the second fails at `XCTAssertTrue`.

**Verify**:
- `Scripts/test.sh --only iMCPTests/LocationWindowModelTests` → all pass: the
  four original tests plus three new ones (one from Step 2, two from this
  step).
- `grep -n "does not re-read a month" App/Views/LocationWindow.swift` → no
  matches.

Commit: `perf(location): reload the Location window when history changes, not every minute`

### Step 5: Attach the search-result handler to a view that survives the change

File: `App/Views/LocationWindow.swift`, `AddPlaceSheet`.

1. Delete the `.onChange(of: chosen) { ... }` modifier from the `List`
   (`:1086-1090`), leaving `.frame(height: 180)` as the list's last modifier.
2. Delete the `snapToHistory(_:)` method (`:1170-1173`).
3. Add this modifier to the sheet's root `VStack`, after `.frame(width: 460)`
   (`:1134`):

   ```swift
           .task(id: chosen) {
               guard let chosen else { return }
               name = chosen.name ?? ""
               let coordinate = chosen.placemark.coordinate
               let found = await model.snap(near: coordinate.latitude, longitude: coordinate.longitude)
               // "Change" clears the choice while this is still looking.
               guard !Task.isCancelled else { return }
               snap = found
           }
   ```

   `.task(id:)` cancels the previous task when `chosen` changes, including to
   `nil`, so a late answer can no longer repopulate `snap`.

This is a view-only change with no unit test; it is covered by the build and by
the manual check in "Maintenance notes".

**Verify**:
- `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` → exit 0.
- `grep -n "snapToHistory\|onChange(of: chosen)" App/Views/LocationWindow.swift` → no matches.

Commit: `fix(location): run the Add Place lookup from the sheet, not the list it replaces`

### Step 6: Settings shows a failed delete and a current summary

File: `App/Views/SettingsView.swift`.

1. In `LocationHistorySection`, add a stored property above the `@State` ones:

   ```swift
       let revision: Int
   ```

   and change `.task { await load() }` (`:826-828`) to
   `.task(id: revision) { await load() }`.

2. Add one helper next to `load()`, modelled on `run` at `:738-752`, and use it
   in both alerts:

   ```swift
       /// A failed delete keeps its error on screen: reloading after it would
       /// succeed and wipe the message.
       private func delete(_ operation: @escaping @MainActor () async throws -> Void) {
           Task { @MainActor in
               do {
                   try await operation()
                   await load()
               } catch {
                   failure = error.localizedDescription
               }
           }
       }
   ```

   ```swift
               Button("Delete", role: .destructive) {
                   delete { try await LocationHistoryStore.shared.deleteSamples() }
               }
   ...
               Button("Delete", role: .destructive) {
                   delete { try await LocationHistoryStore.shared.deletePeopleSamples() }
               }
   ```

   Each call replaces the nine-line `Task { do { ... } catch { ... } await load() }`
   block at `:832-839` and `:849-856`. Keep `error.localizedDescription`
   exactly as it is; the wording of error text belongs to plan 042.

3. In `GeneralSettingsView`: add `@State private var historyRevision = 0` with
   the other `@State` properties (`:325-328`); change the two construction
   lines (`:424-426`) to

   ```swift
               FindMyPeopleSettingsSection(historyChanged: { historyRevision += 1 })

               LocationHistorySection(revision: historyRevision)
   ```

   and add after `.formStyle(.grouped)` (`:450`):

   ```swift
           .onReceive(
               NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
           ) { _ in
               historyRevision += 1
           }
   ```

4. In `FindMyPeopleSettingsSection`: add `let historyChanged: () -> Void` as its
   first stored property (above `@AppStorage`, `:594`), and in the Purge
   button's closure (`:703`) add one line so the summary reloads whether or not
   the later key deletion fails (history is deleted first;
   `App/Services/Location/FindMyPeopleReadiness.swift:229-248`):

   ```swift
                   run {
                       defer { historyChanged() }
                       try await FindMyPeopleReadiness.shared.purge(
   ```

   Change nothing else in that section.

There is no unit-test seam for these private views; do not build one.

**Verify**:
- `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` → exit 0.
- `grep -c "failure = error.localizedDescription" App/Views/SettingsView.swift`
  → one fewer than before this step (the two alert copies became one helper;
  `load()` keeps its own).
- `grep -n "FindMyPeopleSettingsSection()\|LocationHistorySection()" App/Views/SettingsView.swift`
  → no matches.

Commit: `fix(settings): keep a failed history delete visible; refresh the summary after a purge`

### Step 7: Format and run everything

1. `swift format -i -r .`
2. `swift format lint --strict --recursive .` → exit 0.
3. `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` → exit 0.
4. `Scripts/test.sh` → all pass.
5. `git status --short` → only the in-scope files are modified.

If formatting changed files, commit: `style: format`.

## Test plan

New tests, all in existing files (no `project.pbxproj` edit):

| Test | File / class | Covers |
|---|---|---|
| `testStoppingTheSamplerClearsItsLastFailure` | `iMCPTests/ICloudAuthFlowTests.swift`, `LocationHistoryStoreTests` | `stop()` clears `lastFailure` |
| `testACancelledTickLeavesTheStatusAlone` | same | the regression: a cancelled tick recorded its own cancellation |
| `testANewerReloadReplacesTheOneInFlight` | `iMCPTests/LocationTimelineItemsTests.swift`, `LocationWindowModelTests` | the regression: a slow older reload overwrote a newer one |
| `testTicksReloadOnlyWhenTheStoreChanges` | same | no reload on an unchanged store; reload when a sample lands |
| `testReopeningTheWindowReturnsToToday` | same | `selectedDay` reset on open |

Structural patterns: for the sampler tests,
`testSamplerReusesThePhoneItChoseInsteadOfListingDevicesEveryTick`
(`ICloudAuthFlowTests.swift:2092`); for the window tests,
`testReloadListsTodaysStaysAndNamingWritesThePlaceTheToolsRead`
(`LocationTimelineItemsTests.swift:245`) and
`testWindowRefreshStopsWhenClosedAndRestartsOnReopen` (`:471`).

Existing tests that must keep passing unchanged:
`testWindowRefreshStopsWhenClosedAndRestartsOnReopen` (the tick still calls
`samplerStatus` every interval while open and stops when closed),
`testAddingBySearchSnapsToRecordedFixesAndDeleteRemovesThePlace`,
`testPlaceSaveKeepsSheetsOpenForEmptyNamesAndStorageFailures`,
`testSamplerIgnoresStaleDesiredStateReconciliation`, and everything in
`LocationTimelineItemsTests`.

Verification: `Scripts/test.sh` → all pass, including the 5 new tests.

## Done criteria

ALL must hold:

- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `Scripts/test.sh` passes; the 5 tests in the table above exist and pass
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `grep -rn "trackSamples" App iMCPTests` returns no matches
- [ ] `grep -n "snapToHistory\|does not re-read a month" App/Views/LocationWindow.swift` returns no matches
- [ ] `grep -n "await self?.reload()" App/Views/LocationWindow.swift` returns no matches (the loop calls `tick()`)
- [ ] `grep -n "reconciledGeneration" App/Services/Location/LocationSampler.swift` still returns one match
- [ ] `git diff --stat main -- iMCP.xcodeproj App/Services/Location/LocationHistoryStore.swift App/Services/Location.swift` is empty
- [ ] No files outside the in-scope list are modified (`git status --short`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plans 037 or 040 are not on the branch you started from, or the "Current
  state" excerpts no longer match in shape (for example `reload()` has been
  split up, `LocationHistoryStore.summary()` no longer returns an `Equatable`
  `LocationHistorySummary`, or `sampleWeb` has different `catch` clauses).
- `testWindowRefreshStopsWhenClosedAndRestartsOnReopen` fails after Step 4. It
  means the tick no longer reaches `samplerStatus` on every interval; do not
  edit that test to make it pass.
- `testANewerReloadReplacesTheOneInFlight` hangs. It means the second `reload()`
  is waiting on the first; the design requires the second to cancel and proceed.
  Do not add a timeout to hide it.
- In Step 1, `XCTAssertNotNil(failed.lastFailure)` fails: the scripted failure
  is not reaching `sampleWeb`. Report what `ScriptedTransport` recorded rather
  than changing the production code.
- The build fails with a concurrency diagnostic on `Task { [self] in await load() }`
  or on `.task(id: chosen)` that a capture-list change does not fix in two
  attempts.
- Plan 046 or 048 has already restructured `FindMyPeopleSettingsSection` or
  `GeneralSettingsView` so that Step 6's anchors are gone. Do sub-steps 1 and 2
  of Step 6 only (with `revision` defaulted to `0`), and report the rest.
- Any step appears to need a change to `LocationHistoryStore.swift`,
  `Location.swift`, `ICloudSession.swift` or `project.pbxproj`.
- A step's verification fails twice after a reasonable fix attempt.

## Maintenance notes

- **Do not install.** After the tests pass, the local-dev command is
  `Scripts/install-local.sh run`, but run it only if the operator asks.
- **Manual check for the operator** (needs the installed app and a signed-in
  iCloud session, so not an executor step): open Location, leave it open for
  ten minutes and confirm a new fix appears without touching anything; press
  the day chevrons quickly and confirm the sidebar matches the header; close
  the window on an earlier day, reopen, confirm it shows today; in Add Place,
  pick a result and confirm the name field fills and the "Centred on N recorded
  fixes" line appears; press "Change" immediately after picking and confirm no
  snap line lingers.
- **What the tick trades away.** A change that leaves `summary()` identical is
  not seen until the ten-minute fallback: renaming a place in place, or moving
  its centre, from an MCP client via `location_place_set` while the window is
  open. Changes made in the window itself reload immediately. If that ever
  matters, widen the comparison; do not bring back the per-minute full reload.
- **`summary()` is now on a 60 s path.** It is one aggregate over `samples`
  plus a place count. If plan 040 or a later change makes it expensive, the
  tick is the caller to revisit.
- **Reviewer focus**: `reload()` must stay the only entry point that starts
  `load()`; a new direct `load()` call reintroduces overlapping reloads. In
  `sampleWeb`, every write to `status` or `trackedPhone` after an `await` must
  sit below a cancellation check.
- **Interaction with plan 040**: it rewrites the error text at
  `LocationSampler.swift:199-200` and may change how `samples(...)` truncates.
  Neither changes this plan's design; only the excerpts move.
- **Deferred on purpose**: caching the month for `snap(near:)`; running
  inference off the main actor; pausing the tick while the window is
  miniaturised (a tick is now one small query and one actor hop, so the pause
  would be more code than it saves); deleting `reconciledGeneration`.
- **Net size**: production code about +10 lines (roughly +45 for `tick`, the
  `reload` wrapper, the guards and the Settings wiring; roughly -35 for the four
  view computed properties, `trackSamples`, `snapToHistory`, the `onChange`
  block and the duplicated delete block). Tests about +170 lines. The plan is
  not net-negative; what it removes is work at run time.
