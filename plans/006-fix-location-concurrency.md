# Plan 006: Make LocationService concurrency-safe and stop continuous updates

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- App/Services/Location.swift`
> If `App/Services/Location.swift` changed since this plan was written, compare
> the "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

`LocationService` has four related defects in one file:

1. **Leaked continuation** — `activate()` stores a single
   `authorizationContinuation` and, in the `.notDetermined` branch, returns
   without resuming (it waits for the delegate). The class is a plain
   `final class` (no actor / `@MainActor` isolation), so two concurrent
   `activate()` calls (a UI toggle and a tool invocation) overwrite the stored
   continuation — the first is never resumed and its caller hangs forever.
2. **Data race** — `latestLocation` and the `CLLocationManager` are written by
   the CoreLocation delegate callbacks and simultaneously read/mutated by the
   `location_current` tool's busy-poll task, with no isolation. This is a
   Thread Sanitizer hard error and can produce torn/stale reads in production.
3. **Battery drain** — `init()` calls `startUpdatingLocation()` when already
   authorized, and because the service is a `static let shared` singleton its
   `deinit` never runs, so continuous location updates run for the entire app
   lifetime even if no tool is ever called; `location_current` also busy-polls
   `latestLocation` every 100 ms instead of resuming from the delegate.
4. **Authorization-level mismatch** — `activate()` requests and accepts
   `.authorizedWhenInUse`, but `isActivated` and `location_current` require
   `.authorizedAlways`. A successful macOS When In Use permission grant can
   still leave the service toggle/tool path reporting "not authorized."

After this plan, activation is serialized (no leaked continuations), all mutable
state is isolated to `@MainActor`, and location is fetched on demand with
`requestLocation()` instead of running continuously. The service also treats
When In Use and Always as valid authorization levels consistently.

## Current state

- `App/Services/Location.swift` — the whole service. It is a
  `final class ... : NSObject, Service, CLLocationManagerDelegate` with
  `static let shared` (line 20).

Key excerpts:

`init()` starts continuous updates (`Location.swift:22-34`):

```swift
override init() {
    super.init()
    locationManager.delegate = self
    let status = locationManager.authorizationStatus
    if (status == .authorizedAlways) && CLLocationManager.locationServicesEnabled() {
        locationManager.startUpdatingLocation()   // runs forever (singleton)
    }
}
```

`activate()` stores a single continuation (`Location.swift:47-89`):

```swift
func activate() async throws {
    try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        self.authorizationContinuation = continuation   // overwritten by concurrent call
        ...
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()   // returns, waits for delegate
        ...
    }
}
```

`location_current` busy-polls (`Location.swift:105-178`, key part 132-162):

```swift
self.locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
self.locationManager.startUpdatingLocation()
let location = await withTaskGroup(of: CLLocation?.self) { group in
    group.addTask {
        while self.latestLocation == nil {          // busy-poll every 100ms
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return nil }
        }
        return self.latestLocation
    }
    group.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000); return nil }
    for await result in group { group.cancelAll(); return result }
    return nil
}
self.locationManager.stopUpdatingLocation()
```

Delegate callbacks write shared state (`Location.swift:381-419`):

```swift
func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    if let location = locations.last { self.latestLocation = location }
}
func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
    switch status {
    case .authorizedWhenInUse, .authorizedAlways:
        authorizationContinuation?.resume()
        authorizationContinuation = nil
    ...
    }
}
```

Authorization mismatch (`Location.swift:41-45`, `:56-75`, and `:110-122`):

```swift
var isActivated: Bool {
    get async {
        return locationManager.authorizationStatus == .authorizedAlways
    }
}
...
case .authorizedWhenInUse, .authorizedAlways:
    continuation.resume()
...
locationManager.requestWhenInUseAuthorization()
...
guard status == .authorizedAlways else {
    log.error("Location access not authorized")
```

The project Info.plist build settings include both
`NSLocationAlwaysAndWhenInUseUsageDescription` and
`NSLocationWhenInUseUsageDescription`, but the code currently calls
`requestWhenInUseAuthorization()`. Match the code's requested permission unless
the maintainer explicitly asks to require Always.

**Convention reference — the single-resume pattern already used in this repo:**
`App/Services/Capture.swift:579-602` guards a continuation with the `ResumeGate`
actor (`App/Shared/ResumeGate.swift`) plus a timeout Task. Reuse that pattern for
any continuation that can be resumed from more than one place.

Note the two `CLGeocoder`-based tools (`location_geocode`,
`location_reverse-geocode`, `Location.swift:181-377`) are self-contained
per-call continuations and are **not** part of this bug — leave them unchanged.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format (write) | `swift format -i -r .` | exit 0 |
| Format lint (CI gate) | `swift format lint --strict --recursive .` | exit 0, no output |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |

Warnings are errors. This change is concurrency-sensitive: after it builds,
if you can run the app, exercise `location_current` once and confirm it returns
without hanging (record in your report).

## Suggested executor toolkit

- Reuse `ResumeGate` (`App/Shared/ResumeGate.swift`) exactly as `Capture.swift`
  does — do not invent a new single-resume mechanism.

## Scope

**In scope**:
- `App/Services/Location.swift`

**Out of scope**:
- `App/Shared/ResumeGate.swift` — reuse, don't modify.
- The two geocoding tools (`location_geocode`, `location_reverse-geocode`).
- `App/Controllers/ServerController.swift` — the `isActivated`/binding plumbing
  is handled by plan 009; do not change how the service is registered.

## Git workflow

- Branch: `advisor/006-fix-location-concurrency`
- Commit per logical unit (isolation change; on-demand fetch; init cleanup) or a
  single cohesive commit; short imperative messages.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Isolate mutable state to @MainActor

Annotate the class `@MainActor` (or convert to an `actor`; `@MainActor` is
simpler here because `CLLocationManager` delegate callbacks are delivered on the
main run loop when the manager is created on the main thread). Add `@MainActor`
to the class declaration. The `CLLocationManagerDelegate` methods and `activate()`
and the tool closures then share main-actor isolation, removing the data race on
`latestLocation` and the manager.

If the `Service` protocol or the tool closure signatures fight the isolation
(e.g. `nonisolated` requirements), STOP and report the exact compiler error
rather than sprinkling `nonisolated(unsafe)`.

**Verify**: build succeeds; no data-race-related warnings.

### Step 2: Guard the authorization continuation against concurrent activate()

Make `activate()` safe when called concurrently. Two acceptable approaches —
pick one and note it:

- **Single-flight**: if `authorizationContinuation != nil`, the second caller
  awaits the same in-flight authorization (queue the continuations in an array
  and resume all of them in the delegate), OR
- **Fail-fast**: if an authorization request is already in flight, the second
  caller throws a clear "authorization already in progress" error.

Whichever you choose, the delegate's `didChangeAuthorization` must resume **every**
waiting continuation and then clear them. No path may leave a stored continuation
unresumed.

**Verify**: read the code and confirm there is no branch where a stored
continuation is overwritten without being resumed. `grep -n "authorizationContinuation" App/Services/Location.swift`
→ every assignment is paired with a resume-or-store-in-collection, and the
delegate resumes all.

### Step 3: Fetch location on demand instead of continuously

- Remove the `startUpdatingLocation()` call from `init()` (Step from
  `Location.swift:30-33`). `init()` should only set the delegate and desired
  accuracy.
- In `location_current`, replace the `startUpdatingLocation()` + 100 ms busy-poll
  with a single `requestLocation()` bridged through a `ResumeGate`-guarded
  continuation plus a timeout (mirror `Capture.swift:579-602`): the delegate's
  `didUpdateLocations` resumes with the fix, `didFailWithError` resumes with the
  error, and a timeout Task resumes with a timeout error — all via one
  `ResumeGate` so only the first wins. Keep an optional short-TTL cache of
  `latestLocation` if you want snappiness, but do not poll.
- Do not store a single location continuation that can be overwritten by a second
  simultaneous `location_current` call. Use one of these explicit policies:
  queue all pending location continuations and resume them all from the next
  delegate result, or fail fast when a location request is already in flight.
  Prefer queued waiters because callers asking for the same current location can
  share one `requestLocation()` call.

**Verify**: `grep -n "startUpdatingLocation\|100_000_000" App/Services/Location.swift`
→ no `startUpdatingLocation` in `init`; no 100 ms poll loop in `location_current`.

### Step 4: Align authorization checks with the requested permission

Make all read-only authorization checks accept the same levels that `activate()`
requests/accepts: `.authorizedWhenInUse` and `.authorizedAlways`.

Recommended shape:

```swift
private var hasLocationAuthorization: Bool {
    switch locationManager.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways:
        return true
    default:
        return false
    }
}
```

Use the helper in `isActivated` and `location_current` instead of checking only
`.authorizedAlways`. Keep `requestWhenInUseAuthorization()` unchanged unless the
maintainer explicitly decides the tool must require Always permission.

**Verify**:
`grep -n "authorizedAlways" App/Services/Location.swift`
-> no single-level guard remains for `isActivated` or `location_current`; any
remaining matches are part of the two-level helper/switch or comments.

### Step 5: Format and build

Run `swift format -i -r .` then build.

**Verify**: the build command exits 0; `swift format lint --strict --recursive .` exits 0.

## Test plan

No App-side unit-test target exists yet. Because this is concurrency and
delegate-driven, unit testing requires injecting a fake location manager, which
is out of scope here. Verification is:
- Build clean with `@MainActor` isolation (compiler enforces the race is gone).
- Manual: if you can run the app with location authorized, call `location_current`
  and confirm it returns a coordinate promptly and does not hang; toggle the
  Location service while a call is in flight and confirm no hang. Record results.
- If a Thread Sanitizer scheme is available, note whether the previous TSan
  report on `latestLocation` is gone (optional).

## Done criteria

ALL must hold:

- [ ] `LocationService` is `@MainActor`-isolated (or an actor); `latestLocation`
      and the manager are no longer accessed without isolation
- [ ] No code path overwrites `authorizationContinuation` without resuming it;
      the delegate resumes all waiters
- [ ] `init()` no longer calls `startUpdatingLocation()`
- [ ] `location_current` uses `requestLocation()` + `ResumeGate` + timeout, with
      no 100 ms busy-poll
- [ ] Simultaneous `location_current` calls cannot overwrite each other's
      continuations; they either share one in-flight request or fail fast clearly
- [ ] `isActivated` and `location_current` accept `.authorizedWhenInUse` and
      `.authorizedAlways` consistently
- [ ] `xcodebuild ... build` exits 0
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] Only `App/Services/Location.swift` and `plans/README.md` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- Adding `@MainActor` produces protocol-conformance errors on `Service` or the
  `Tool` closure types that can't be resolved without changing files outside
  scope — report the exact error.
- The maintainer or Apple API behavior requires Always authorization for this
  tool; if so, STOP and report the product/API reason before changing
  `activate()` to request a broader permission.
- The code doesn't match the "Current state" excerpts (drift).

## Maintenance notes

- This plan intentionally standardizes on When In Use because that is what the
  current code requests. If a future feature truly needs continuous/background
  location, revisit both the request API and user-facing copy together.
- Reviewer should scrutinize the delegate's resume-all logic for the concurrent
  activation case and confirm the timeout can't double-resume (ResumeGate
  prevents it, but verify it's wired to every resume site).
