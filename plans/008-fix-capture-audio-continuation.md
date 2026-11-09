# Plan 008: Guard the `capture_record_audio` continuation and clean up its temp file

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- App/Services/Capture.swift`
> If `App/Services/Capture.swift` changed since this plan was written, compare
> the "Current state" excerpt against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

`capture_record_audio` bridges its result through a bare
`withCheckedThrowingContinuation` with an inner `Task` that sleeps for the
recording duration, then stops the recorder and resumes. Unlike the sibling
capture tools (`capture_take_picture`, `capture_take_screenshot`), it has **no
single-resume guard and no timeout**. If the inner `Task.sleep` throws because
the task is cancelled — which happens when the MCP connection drops mid-recording
— the closure exits without ever resuming the continuation, so the request hangs
forever. On the read/`removeItem` error path the temp audio file also leaks into
`NSTemporaryDirectory()`. After this plan, the audio path uses the same
`ResumeGate` + timeout pattern as the other capture tools and always cleans up
its temp file.

## Current state

- `App/Services/Capture.swift` — the Capture service; `capture_record_audio` tool.

Current audio continuation (`Capture.swift:382-399`):

```swift
let recorder = try AVAudioRecorder(url: tempURL, settings: settings)
recorder.record(forDuration: duration)

return try await withCheckedThrowingContinuation { continuation in
    Task {
        try await Task.sleep(for: .seconds(duration + 0.5))   // throws on cancellation → no resume
        recorder.stop()
        do {
            let audioData = try Data(contentsOf: tempURL)
            try FileManager.default.removeItem(at: tempURL)     // only removed on success path
            let audioValue = Value.data(mimeType: format.mimeType, audioData)
            continuation.resume(returning: audioValue)
        } catch {
            continuation.resume(throwing: error)                // temp file leaks here
        }
    }
}
```

**The pattern to copy — `capture_take_screenshot` (`Capture.swift:579-602`):**

```swift
return try await withCheckedThrowingContinuation { continuation in
    let resumeGate = ResumeGate()
    let resumeOnce: (Result<Value, Error>, (() async -> Void)?) async -> Void = { result, _ in
        guard await resumeGate.shouldResume() else { return }
        continuation.resume(with: result)
    }
    let timeoutTask = Task {
        try await Task.sleep(for: .seconds(10))
        await resumeOnce(.failure(NSError(domain: "CaptureServiceError", code: 26,
            userInfo: [NSLocalizedDescriptionKey: "Screenshot capture timeout"])), nil)
    }
    Task { ... on success/failure: await resumeOnce(.success(value), nil) / .failure(error) ... }
}
```

`ResumeGate` is `App/Shared/ResumeGate.swift` (actor, `shouldResume() -> Bool`).
`capture_take_picture` at `Capture.swift:248-258` uses the same idea.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format (write) | `swift format -i -r .` | exit 0 |
| Format lint (CI gate) | `swift format lint --strict --recursive .` | exit 0, no output |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**:
- `App/Services/Capture.swift` — only the `capture_record_audio` continuation
  block (around `Capture.swift:382-399`).

**Out of scope**:
- `capture_take_picture` and `capture_take_screenshot` — already correct; do not
  modify.
- `App/Shared/ResumeGate.swift` — reuse, don't change.
- The recording settings / format logic above line 382 — unchanged.

## Git workflow

- Branch: `advisor/008-fix-capture-audio-continuation`
- Single commit; short imperative message.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Wrap the audio continuation with ResumeGate + timeout

Rewrite the `capture_record_audio` continuation to mirror
`capture_take_screenshot`:

- Create a `ResumeGate` and a `resumeOnce` helper that resumes at most once.
- Add a timeout Task with a duration comfortably longer than `duration + 0.5`
  (e.g. `duration + 5` seconds) that resumes with a timeout error so a stuck
  recorder can't hang forever.
- In the recording Task, wrap the sleep/stop/read in `do/catch`; on **any** exit
  path — success, thrown read error, or cancellation — go through `resumeOnce`.
- Ensure the recorder is stopped and the temp file removed on every path (see
  Step 2).

**Verify**: `grep -n "ResumeGate\|resumeOnce" App/Services/Capture.swift` shows
the audio tool now uses the gate (previously only the screenshot/picture tools
did).

### Step 2: Always clean up the temp file

Move temp-file removal to a `defer` (or an explicit cleanup in every branch) so
the file is deleted whether the read succeeds, fails, or the task is cancelled.
The `Value.data(...)` must be constructed from the read bytes **before** removal.

**Verify**: read the code — no path returns/throws without removing `tempURL`.

### Step 3: Format and build

Run `swift format -i -r .` then build.

**Verify**: `** BUILD SUCCEEDED **`; `swift format lint --strict --recursive .` exits 0.

## Test plan

No App-side unit-test target exists yet; this is AVFoundation-driven. Verification:
- Build clean.
- Manual (record results): if you can run the app, call `capture_record_audio`
  with a short duration and confirm it returns audio. If feasible, drop the
  connection mid-recording (or cancel the client request) and confirm the call
  does not leave a hung request and no `shortcut_*`/audio temp file remains in
  `NSTemporaryDirectory()`.

## Done criteria

ALL must hold:

- [ ] `capture_record_audio` uses `ResumeGate` + a timeout Task; no path leaves
      the continuation unresumed
- [ ] The temp audio file is removed on success, failure, and cancellation paths
- [ ] `xcodebuild ... build` prints `** BUILD SUCCEEDED **`
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] Only `App/Services/Capture.swift` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- The audio block doesn't match the "Current state" excerpt (drift).
- `AVAudioRecorder`'s `record(forDuration:)` + manual stop interacts with the
  timeout in a way that truncates recordings unexpectedly — report before
  shipping a behavior change to recording length.

## Maintenance notes

- All three capture tools now share the ResumeGate+timeout shape; if a fourth
  capture tool is added, follow the same pattern.
- Reviewer should confirm the timeout duration can't fire before a legitimate
  recording of the requested `duration` completes.
