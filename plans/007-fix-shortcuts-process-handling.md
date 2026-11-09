# Plan 007: Fix Shortcuts process handling — termination race and pipe deadlock

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- App/Services/Shortcuts.swift`
> If `App/Services/Shortcuts.swift` changed since this plan was written, compare
> the "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

Two defects in `ShortcutsService` can permanently hang a tool call:

1. **Termination-handler race** — `runProcess` calls `process.run()` and only
   *then* installs `process.terminationHandler` inside the continuation. A
   short-lived process (like `shortcuts list`) can exit before the handler is
   installed, so the handler never fires and the continuation is never resumed —
   the call hangs forever. `listShortcuts` has no timeout backstop (unlike
   `runShortcut`), so nothing rescues it.
2. **Pipe-buffer deadlock** — `listShortcuts` reads the stdout pipe only *after*
   the process terminates. If the shortcut list exceeds the ~64 KB OS pipe
   buffer, the child process blocks writing, never exits, and `runProcess` never
   returns.

After this plan, the termination handler is installed before `run()` (with an
already-exited fast path), pipes are drained concurrently while the process runs,
and `listShortcuts` cannot deadlock on large output.

## Current state

- `App/Services/Shortcuts.swift` — the Shortcuts service.

`runProcess` installs the handler after `run()` (`Shortcuts.swift:67-74`):

```swift
private func runProcess(_ process: Process) async throws {
    try process.run()
    await withCheckedContinuation { continuation in
        process.terminationHandler = { _ in     // race: process may have already exited
            continuation.resume()
        }
    }
}
```

`listShortcuts` reads pipes only after termination (`Shortcuts.swift:76-132`,
key part):

```swift
let outputHandle = outputPipe.fileHandleForReading
let errorHandle = errorPipe.fileHandleForReading
defer { outputHandle.closeFile(); errorHandle.closeFile() }
do {
    try await runProcess(process)   // returns only after process exits
} catch { ... }
let outputData = (try? outputHandle.readToEnd()) ?? Data()   // drained too late
let errorData = (try? errorHandle.readToEnd()) ?? Data()
```

For contrast, `runShortcut` (`Shortcuts.swift:134-235`) already wraps execution
in a `withThrowingTaskGroup` with a 5-minute timeout task
(`Shortcuts.swift:168-188`) and avoids stdout buffering by using
`--output-path` to a temp file. That timeout pattern is the model to extend.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format (write) | `swift format -i -r .` | exit 0 |
| Format lint (CI gate) | `swift format lint --strict --recursive .` | exit 0, no output |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**:
- `App/Services/Shortcuts.swift`

**Out of scope**:
- The MCP tool schemas / tool names — behavior of the tools is unchanged; only
  the process plumbing is fixed.
- `runShortcut`'s existing timeout logic — you may reuse it, but its
  `--output-path` design already avoids the stdout deadlock; don't rework it
  beyond adopting the fixed `runProcess`.

## Git workflow

- Branch: `advisor/007-fix-shortcuts-process-handling`
- Commit per fix or one cohesive commit; short imperative messages.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Install the termination handler before run(), with an already-exited fast path

Rewrite `runProcess` so the handler is set before `run()` and an
already-terminated process resolves immediately. Use a `ResumeGate`-style single
resume so the "already exited" check and the handler can't both fire. Target
shape:

```swift
private func runProcess(_ process: Process) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let gate = ResumeGate()
        process.terminationHandler = { _ in
            Task { if await gate.shouldResume() { continuation.resume() } }
        }
        do {
            try process.run()
        } catch {
            Task { if await gate.shouldResume() { continuation.resume(throwing: error) } }
            return
        }
        // Guard the race where the process exited before the handler was installed.
        if !process.isRunning {
            Task { if await gate.shouldResume() { continuation.resume() } }
        }
    }
}
```

`ResumeGate` is at `App/Shared/ResumeGate.swift` (an actor with
`shouldResume() -> Bool`). Import is not needed (same module).

**Verify**: build succeeds; `grep -n "terminationHandler" App/Services/Shortcuts.swift`
→ handler assigned before `process.run()`.

### Step 2: Drain stdout/stderr concurrently in listShortcuts

Change `listShortcuts` so it reads the output and error pipes *while* the process
runs, not after. Start reader tasks (or use `fileHandleForReading.readToEnd()` on
a background task) concurrently with `runProcess`, then join. Target approach:
launch a `withThrowingTaskGroup` that runs the process and reads both pipes in
parallel, collecting the data; this removes the >64 KB deadlock.

Keep the existing parsing (split on newlines, trim, filter empties,
`Shortcuts.swift:123-131`) unchanged — only the *timing* of the reads changes.

**Verify**: build succeeds; read the code and confirm pipe reads are not
sequenced strictly after `runProcess` returns.

### Step 3: Add a timeout backstop to listShortcuts

Wrap `listShortcuts`'s execution in the same timeout pattern `runShortcut` uses
(`withThrowingTaskGroup` + a `Task.sleep` timeout that terminates the process and
throws). A shorter timeout than 5 minutes is appropriate for a `list` command
(e.g. 30–60 s); pick one and note it.

**Verify**: `grep -n "Task.sleep" App/Services/Shortcuts.swift` → a timeout guard
now exists in `listShortcuts` as well as `runShortcut`.

### Step 4: Format and build

Run `swift format -i -r .` then build.

**Verify**: `** BUILD SUCCEEDED **`; `swift format lint --strict --recursive .` exits 0.

## Test plan

No App-side unit-test target exists yet, and these are `Process`-driven paths.
Verification:
- Build clean.
- Manual (record results): if you can run the app, call `shortcuts_list` and
  confirm it returns and doesn't hang; if the machine has many shortcuts,
  confirm large output doesn't deadlock. Call `shortcuts_run` on a fast-exiting
  shortcut and confirm it returns.
- If plan 014 introduces an App test target and the process logic gets extracted
  behind a seam, a fake-process test can follow — deferred, note it.

## Done criteria

ALL must hold:

- [ ] `runProcess` installs `terminationHandler` before `process.run()` and
      resolves immediately if `!process.isRunning`, guarded against double-resume
- [ ] `listShortcuts` drains stdout/stderr concurrently with execution
- [ ] `listShortcuts` has a timeout backstop
- [ ] `xcodebuild ... build` prints `** BUILD SUCCEEDED **`
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] Only `App/Services/Shortcuts.swift` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- The code doesn't match the "Current state" excerpts (drift).
- Reusing `ResumeGate` causes an isolation/Sendable error you can't resolve
  within this file — report the exact error.
- The `shortcuts` binary path (`/usr/bin/shortcuts`, `Shortcuts.swift:10`) or
  the sandbox prevents launching a subprocess at all in your environment —
  report; that's an environment limitation, not a code fix.

## Maintenance notes

- `runShortcut` also reads stderr only after termination (`Shortcuts.swift:193`,
  `:202-203`), a smaller version of the same risk (stderr is usually small).
  Consider applying the same concurrent-drain there; deferred to keep this plan
  focused — note it for the maintainer.
- Reviewer should confirm the already-exited fast path and the terminationHandler
  can't both resume the continuation.
