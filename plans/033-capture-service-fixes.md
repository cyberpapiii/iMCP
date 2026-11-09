# Plan 033: Fix Capture activation, delay timeout, display selection, and payload size

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 17d7c72..HEAD -- App/Services/Capture.swift App/Controllers/ServiceRegistry.swift App/Extensions/ScreenCaptureKit+Extensions.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M (four independent fixes in one file)
- **Risk**: MED — `Capture.swift` uses `withCheckedThrowingContinuation` with a `ResumeGate`; two prior plans (008 and commit `fc769e5`) were needed to get its resume paths right. Do not restructure the continuation scaffold.
- **Depends on**: plans/029-verification-baseline.md
- **Category**: bug
- **Planned at**: commit `17d7c72`, 2026-08-07

## Why this matters

`App/Services/Capture.swift` was substantially rewritten recently (322 lines
changed) and shipped with four independent defects, three of them user-visible:

1. **The service reports itself broken unless all three permissions are
   granted.** `isActivated` requires Camera **and** Microphone **and** Screen
   Recording, while the user-facing guidance string says "Camera, Microphone,
   **or** Screen Recording". A user who granted only Camera sees a permanent
   warning badge and a repair prompt for a service whose camera tool works
   fine.
2. **Any `capture_take_picture` with `delay` above ~9 seconds always fails.**
   The schema advertises `maximum: 60`, but the capture is wrapped in a fixed
   10-second timeout that the delay runs inside.
3. **Screenshots of a chosen secondary display are sized from the primary
   display.** The code selects the requested display for the content filter,
   then computes the output dimensions from `displays.first` regardless.
4. **Capture output is unbounded.** At `quality: "max"` the scale factor is
   `2.0` against native display dimensions, PNG-encoded and base64'd into a
   single JSON-RPC message. The CLI proxy's buffers are 10 MB, and the whole
   blob lands in the client's context window. Every other image path in this
   repo is already bounded — `photos_fetch_image` has a `maxDimension`
   defaulting to 2048, and plan 018 added the same bound to `maps_generate`.
   Capture is the last unbounded one.

## Current state

### Defect 1 — activation predicate contradicts its own guidance

```swift
// App/Services/Capture.swift:50-57
    var isActivated: Bool {
        get async {
            let cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            let microphoneAuthorized =
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
            return cameraAuthorized && microphoneAuthorized && screenRecordingAuthorized
        }
    }
```

```swift
// App/Controllers/ServiceRegistry.swift:135-138
                permissionGuidance: ServicePermissionGuidance(
                    explanation: "Needs Camera, Microphone, or Screen Recording access. Click to grant.",
                    settingsPaneURL: ServicePermissionGuidance.privacyPane("Privacy_Camera")
                )
```

### Defect 2 — fixed 10s timeout swallows the advertised 60s delay

```swift
// App/Services/Capture.swift:163-168 — the schema
                    "delay": .number(
                        description: "Delay before taking photo, in seconds",
                        default: 1,
                        minimum: 0,
                        maximum: 60
                    ),
```

```swift
// App/Services/Capture.swift:589 — the value
        let delay = arguments["delay"]?.doubleValue ?? 1.0
```

```swift
// App/Services/Capture.swift:655-662 — the fixed timeout
            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(10))
                await resumeOnce(
                    .failure(
                        NSError(
                            domain: "CaptureServiceError",
                            code: 9,
                            userInfo: [NSLocalizedDescriptionKey: "Camera capture timeout"]
```

The delay runs **inside** that window:

```swift
// App/Services/Capture.swift:674-678
            Task { @MainActor in
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
```

### Defect 3 — output sized from the wrong display

The requested display is resolved correctly for the content filter at
`App/Services/Capture.swift:377-384` (`availableContent.displays.first(where: { $0.displayID == displayId })`),
but the dimensions come from `displays.first`:

```swift
// App/Services/Capture.swift:471-478
            // Apply quality settings based on the display
            if let display = availableContent.displays.first {
                let scaledWidth = Int(CGFloat(display.width) * quality.scaleFactor)
                let scaledHeight = Int(CGFloat(display.height) * quality.scaleFactor)
                streamConfiguration.width = scaledWidth
                streamConfiguration.height = scaledHeight
            }
```

### Defect 4 — no upper bound on output dimensions

```swift
// App/Extensions/ScreenCaptureKit+Extensions.swift:25-33
        case .low:
            return 0.5
        case .medium:
            return 0.75
        case .high:
            return 1.0
        case .max:
            return 2.0
```

The pattern to copy is in the Photos service:

```swift
// App/Services/Photos.swift:331-336
                    "maxDimension": .integer(
                        description:
                            "Maximum width or height in pixels; larger images are scaled down",
                        default: 2048,
                        minimum: 1
                    ),
```

### Also present in this file (fix only where this plan says so)

- `App/Services/Capture.swift:35-37` declares `captureSession`, `audioRecorder`,
  `photoOutput` as stored properties that are **never assigned** — the rewrite
  made all three local. Consequently `deinit` (`:44-48`) calls
  `captureSession?.stopRunning()` and `audioRecorder?.stop()` on permanently-`nil`
  values, so the cleanup it appears to perform does not happen.
- Error code `26` is used for two different failures: "No displays available for
  application capture" (`:452`) and "Screenshot capture timeout" (`:495`).

### Conventions

- Errors are `NSError(domain: "CaptureServiceError", code: <int>, userInfo: [NSLocalizedDescriptionKey: ...])`.
  Codes are unique per failure — that is the intent, and defect-adjacent code
  `26` violates it.
- Continuations use `ResumeGate` (`App/Shared/ResumeGate.swift`) with a
  `resumeOnce` closure. **Do not refactor this scaffold** — see Out of scope.
- Tool input schemas use `JSONSchema` builders as shown above.
- `swift format`: 4-space indent, 120-column limit.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| App tests | `xcodebuild test -scheme iMCP -destination "platform=macOS"` | exit 0, `TEST SUCCEEDED` |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

`-quiet` suppresses the success marker — **success is exit code 0**.

## Scope

**In scope** (the only files you should modify):
- `App/Services/Capture.swift`
- `App/Extensions/ScreenCaptureKit+Extensions.swift` (only if the clamp helper
  belongs there)
- `iMCPTests/ClaudeDesktopConfigTests.swift` — despite its name, this file
  already contains `CameraPhotoCaptureGateTests` (at roughly `:121-155`), which
  is the **only** existing Capture coverage. Add new Capture tests there.

**Out of scope** (do NOT touch, even though they look related):
- The `withCheckedThrowingContinuation` + `ResumeGate` + `timeoutTask` scaffold
  itself, which appears three times (`:258-300`, `:480-548`, `:643-699`).
  Unifying it is a real cleanup, but plan 008 and commit `fc769e5` were both
  needed to get these resume paths correct; changing the shape here risks
  reintroducing a continuation leak. Change only the timeout **duration** and
  the error **code**, never the control flow.
- The dead stored properties at `:35-37` and the no-op `deinit` at `:44-48`.
  They are genuinely dead and misleading, but deleting them is a separate
  concern from these four behavior fixes — see Maintenance notes.
- `App/Services/Photos.swift` — it is the pattern to copy, not a file to edit.
- Adding a new test **file** — test targets are hand-maintained in
  `project.pbxproj` and a new file would silently never run. Add cases to the
  existing test file named above.

## Git workflow

- Branch: `advisor/033-capture-service-fixes`
- Conventional commits, e.g. `fix: derive capture timeout from requested delay`.
- **Commit each step separately** — these are four independent fixes and a
  reviewer should be able to read them apart.
- Do NOT push or open a PR unless the operator asks.

## Steps

### Step 1: Make activation match the guidance

Change `isActivated` (`App/Services/Capture.swift:50-57`) to return `true` when
**any** of the three authorizations is granted, so the predicate matches the
"Camera, Microphone, or Screen Recording" guidance string at
`App/Controllers/ServiceRegistry.swift:136`.

Keep the three individual checks as separate locals — they stay readable and
the follow-up (per-tool activation, see Maintenance notes) will want them.

**Verify**:
```console
grep -n "cameraAuthorized || microphoneAuthorized || screenRecordingAuthorized" App/Services/Capture.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ one match, `exit=0`.

### Step 2: Derive the camera timeout from the requested delay

At `App/Services/Capture.swift:655-656`, replace the fixed
`try await Task.sleep(for: .seconds(10))` with a timeout computed from the
`delay` value read at `:589`:

```swift
let captureTimeout = delay + 10.0
```

and sleep for `captureTimeout`. Define it near the `delay` binding so the
relationship is obvious, and add a brief comment noting that the delay elapses
inside the timeout window, so the budget must include it.

Do not change the error code (`9`), the error message, or the `resumeOnce`
control flow.

**Verify**:
```console
grep -n "delay + 10" App/Services/Capture.swift
grep -c "Task.sleep(for: .seconds(10))" App/Services/Capture.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ one match for the first; the second count must be **lower** than before your
edit (record the before-value first); `exit=0`.

### Step 3: Size the screenshot from the display actually being captured

The `switch contentType` block at `App/Services/Capture.swift:375-463` already
resolves the correct `SCDisplay` for the `.display` case. Hoist that resolved
display (and, for the `.application` case, the `firstDisplay` it already picks
at `:449`) into a variable visible at `:471`, and use it instead of
`availableContent.displays.first`.

Requirement: for a `.display` capture with an explicit `displayId`, the
dimensions must come from **that** display. Do not change which display is
captured — only which display's dimensions size the output.

**Verify**:
```console
grep -c "availableContent.displays.first {" App/Services/Capture.swift   # the sizing site is gone
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ `0` and `exit=0`.

### Step 4: Give the two capture tools a `maxDimension` bound

Add a `maxDimension` input to the **screenshot** tool and the **camera photo**
tool, copying the schema shape from `App/Services/Photos.swift:331-336`
(`.integer`, `default: 2048`, `minimum: 1`, same description wording).

Then clamp:
- For the screenshot path, after computing `scaledWidth`/`scaledHeight` in
  Step 3, scale both down proportionally so neither exceeds `maxDimension`
  before assigning `streamConfiguration.width`/`.height`. Preserve aspect
  ratio; never scale **up** if the capture is already smaller.
- For the camera photo path, apply the same clamp to the produced image before
  encoding.

Write the clamp once as a small helper (a private function in `Capture.swift`,
or in `App/Extensions/ScreenCaptureKit+Extensions.swift` if it fits the existing
extension style there) and call it from both sites.

**Verify**:
```console
grep -c "maxDimension" App/Services/Capture.swift    # expect >= 2 (both tool schemas)
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ `≥ 2` and `exit=0`.

### Step 5: Disambiguate the duplicated error code

Error code `26` is used at `App/Services/Capture.swift:452` ("No displays
available for application capture") and again at `:495` ("Screenshot capture
timeout"). Give the timeout a distinct unused code. Confirm your chosen code is
unused first:

```console
grep -n "code: " App/Services/Capture.swift | sort -u
```

Pick a value not in that list.

**Verify**: `grep -c "code: 26" App/Services/Capture.swift` → `1`.

### Step 6: Add tests

In `iMCPTests/ClaudeDesktopConfigTests.swift`, in or beside the existing
`CameraPhotoCaptureGateTests` class, add pure-function tests for the parts that
are testable without hardware:

1. **Clamp helper — scales down**: an input larger than `maxDimension` in width
   produces an output whose largest side equals `maxDimension` and whose aspect
   ratio is preserved (assert within a tolerance of 1 pixel for rounding).
2. **Clamp helper — never scales up**: an input already smaller than
   `maxDimension` is returned unchanged.
3. **Clamp helper — square and portrait inputs** clamp on the correct axis.
4. **Timeout derivation**: `delay + 10` for representative delays (0, 1, 60),
   confirming a 60-second delay yields a 70-second budget — the regression that
   makes the advertised `maximum: 60` usable.

The activation predicate (Step 1), display selection (Step 3), and actual
capture need real hardware and TCC grants; they are **manually verified only**.
State that explicitly in your report rather than writing a test that asserts
nothing.

To make cases 1–4 testable, the clamp and the timeout derivation must be pure
functions with `internal` access, not logic inlined in the capture closure.

**Verify**: `xcodebuild test -scheme iMCP -destination "platform=macOS" ; echo "exit=$?"` → `exit=0` with 4+ new tests.

### Step 7: Run the full gate

```console
swift format -i -r .
swift format lint --strict --recursive . ; echo "exit=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS" ; echo "exit=$?"
xcodebuild test -scheme iMCP -destination "platform=macOS" ; echo "exit=$?"
```

**Verify**: all four print `exit=0`.

## Test plan

- **New** in `iMCPTests/ClaudeDesktopConfigTests.swift` (beside
  `CameraPhotoCaptureGateTests`): the four cases in Step 6 — clamp scales down,
  clamp never scales up, clamp picks the correct axis, timeout derivation
  including the 60-second case.
- **Structural pattern**: the existing `CameraPhotoCaptureGateTests` class in
  that same file.
- **Manual verification required** (no automated coverage possible): granting
  only Camera shows the Capture service as active rather than badged;
  `capture_take_screenshot` against a secondary display returns that display's
  dimensions; `quality: "max"` output respects `maxDimension`.
- Verification: `xcodebuild test -scheme iMCP -destination "platform=macOS"` →
  all pass, including 4 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "cameraAuthorized || microphoneAuthorized || screenRecordingAuthorized" App/Services/Capture.swift` → `1`
- [ ] `grep -c "delay + 10" App/Services/Capture.swift` → `1`
- [ ] `grep -c "maxDimension" App/Services/Capture.swift` → `≥ 2`
- [ ] `grep -c "code: 26" App/Services/Capture.swift` → `1`
- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `xcodebuild test -scheme iMCP -destination "platform=macOS"` exits 0 with 4+ new tests
- [ ] `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` exits 0
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row for 033 updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any change would require restructuring the `ResumeGate` / `resumeOnce` /
  `timeoutTask` control flow rather than just its duration and error code.
- Hoisting the resolved display in Step 3 turns out to require reshaping the
  `switch contentType` block substantially (more than moving a `let` outward).
- An existing Capture test starts failing.
- You conclude a new test **file** is needed — it would silently never run (test
  targets are hand-maintained in `project.pbxproj`).
- The `maxDimension` clamp cannot be applied to the camera path without
  changing how the photo is encoded — report rather than reworking the encoder.

## Maintenance notes

For the human/agent who owns this code after the change lands:

- **A reviewer should scrutinize** that the continuation scaffold is byte-for-byte
  unchanged apart from the timeout duration and the error code, and that the
  clamp preserves aspect ratio and never scales up.
- **Deferred cleanups in this same file**, each deliberately excluded here:
  1. `:35-37` — `captureSession`, `audioRecorder`, `photoOutput` are stored
     properties never assigned; the `deinit` at `:44-48` therefore performs no
     cleanup while appearing to. Delete both. This reads as live camera/mic
     teardown to anyone auditing the service, and it is not.
  2. `:482-487` — `resumeOnce` takes a cleanup closure it discards (`result, _ in`),
     and all three call sites pass `nil`. Drop the unused parameter.
  3. The timeout scaffold is written out three times; extracting a
     `withTimeout(seconds:_:)` helper over `ResumeGate` deserves its own plan
     with its own tests, given the history of continuation bugs here.
- **Better follow-up for defect 1**: rather than any-of, report **per-tool**
  activation so the badge reflects which capture tools are actually available.
  Collapsing three independent grants into one boolean will keep producing
  confusing UI either way.
- **Related**: `maxDimension` bounds the image, but the transport ceiling is
  separate — the CLI proxy's stdin/network buffers are 10 MB
  (`CLI/main.swift:146-147`). If capture payloads are still too large in
  practice, the real fix is MCP Resources (returning a referenceable URI instead
  of an inline base64 blob); `ListResources` is currently stubbed to return an
  empty list at `App/Controllers/ServerNetworkManager.swift:473-476`.
