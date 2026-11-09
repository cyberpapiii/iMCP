# Plan 023: Remove CLI network-handler busy-polling on empty reads

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 815767f..HEAD -- CLI/main.swift CLITests/ App/Controllers/NWConnectionTransport.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `815767f`, 2026-07-06
- **Executed at**: commit `2db1d34`, branch `advisor/023-cli-network-read-no-poll`
- **Result**: DONE

## Why this matters

`StdioProxy.handleNetworkToStdout` spins when `NWConnection.receive` returns
empty `Data`: it increments `consecutiveEmptyReads` and sleeps 100 ms before
retrying (`CLI/main.swift:390-393`). NWError 96 ("no message available") takes
the same sleep path (`:436-440`). Idle MCP sessions therefore wake ~10 times per
second per connection — unnecessary CPU/battery cost for a menu-bar app's CLI
companion.

The app-side transport already uses continuation-based reads without polling —
see `App/Controllers/NWConnectionTransport.swift:244-258` (`receiveChunk`).

## Current state

Polling loop — `CLI/main.swift:332-458` (key sections):

```swift
if data.isEmpty {
    consecutiveEmptyReads += 1
    try await Task.sleep(for: .milliseconds(100))
    continue
}
// ...
} catch let error as NWError where error.errorCode == 96 {
    consecutiveEmptyReads += 1
    try await Task.sleep(for: .milliseconds(100))
}
```

Timeout escalation uses `consecutiveEmptyReads > maxConsecutiveEmptyReads * 10`
(~100 s of empty reads at 100 ms each) at `:354-363`.

Stdin side uses `DispatchSource.makeReadSource` (`CLI/main.swift:51-96`) —
event-driven, no poll loop.

Existing CLI tests: `CLITests/MessageFrameScannerTests.swift`,
`CLITests/BonjourEndpointSelectionTests.swift` — no network I/O tests yet.

Repo commands:

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| CLI tests | `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` | exit 0 |
| Format lint | `swift format lint --strict --recursive .` | exit 0 |

## Scope

**In scope**:

- `CLI/main.swift` (`StdioProxy.handleNetworkToStdout`, optionally extract
  `receiveChunk` helper in same file or `CLI/NetworkReceive.swift`)
- `CLITests/` — only if you add a testable pure helper for timeout math

**Out of scope**:

- stdin handler (already event-driven)
- Shared frame scanner duplication (tech-debt backlog)
- Changing heartbeat / message framing behavior
- App-side `NWConnectionTransport` (reference only)

## Git workflow

- Branch: `advisor/023-cli-network-read-no-poll`
- Commit style: `perf: stop busy-polling CLI network reads on empty data`
- Do NOT push or open a PR unless the operator asks.

## Steps

### Step 1: Replace empty-read sleep loop with blocking receive

Refactor `handleNetworkToStdout` to follow the app transport pattern:

1. Extract a private method on `StdioProxy`:

```swift
private func receiveNetworkChunk(from connection: NWConnection, bufferSize: Int) async throws -> (data: Data, isComplete: Bool)
```

Use `withCheckedThrowingContinuation` + `connection.receive(...)` like
`NWConnectionTransport.receiveChunk` — resume with `(data ?? Data(), isComplete)`.

2. In the read loop:
   - On `(Data(), isComplete: false)` — **continue immediately** without
     `Task.sleep`. Do not treat empty non-complete reads as liveness failures
     unless you implement an explicit idle timeout (step 2).
   - On non-empty data — reset idle timer, run `frameScanner.consume`, write stdout.
   - On `isComplete` — throw `StdioProxyError.connectionClosed`.
   - Remove the NWError 96 special-case sleep branch if receive no longer surfaces
     it through this path; if it still does, retry receive without sleeping.

3. Remove `consecutiveEmptyReads` polling counter **or** repurpose it only for
   idle-timeout tracking (step 2), not per-empty-read increments with sleep.

**Verify**: `grep 'Task.sleep(for: .milliseconds(100))' CLI/main.swift` inside
`handleNetworkToStdout` → no matches.

### Step 2: Preserve idle timeout semantics

The old loop timed out after ~100 s of consecutive empty reads
(`maxConsecutiveEmptyReads * 10` at 100 ms). Replace with an explicit idle
timeout that does not busy-poll:

- Option A (preferred): `Task` + clock — record `lastDataReceived` timestamp;
  if no bytes (including heartbeats) for e.g. 100 seconds, throw
  `StdioProxyError.networkTimeout`. Heartbeats from the app count as data
  (existing comment at `:396-397`).
- Option B: wrap `receiveNetworkChunk` in `withTimeout(seconds: 100)` that
  cancels the receive if no completion — only if you can cancel NW receive cleanly.

Document chosen timeout value in a constant near `maxConsecutiveEmptyReads`
(replace or rename the constant).

**Verify**: manual smoke — run `imcp-server` against a running iMCP app for 30s
idle; CPU should not show sustained wakeups (optional note in commit message if
manual only).

### Step 3: Partial stdout write delay

The 1 ms sleep in the partial-write loop (`CLI/main.swift:431-432`) is separate
from network polling. Leave it unless profiling shows it is unnecessary — out of
scope unless removal is trivial and tests pass.

### Step 4: Format and CLI tests

```console
swift format -i -r .
swift format lint --strict --recursive .
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build
```

All exit 0. Build ensures `imcp-server` target still compiles.

## Test plan

- Existing `imcp-serverTests` must remain green (frame scanner + Bonjour tests).
- No new network integration test required if refactor is structural; optional
  unit test for idle-timeout constant math if extracted.

## Done criteria

- [x] No 100 ms sleep loop on empty network reads in `handleNetworkToStdout`
- [x] Idle timeout behavior preserved (100s via `networkIdleTimeout` + `lastDataReceived`)
- [x] `swift format lint --strict --recursive .` → exit 0
- [x] `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` → exit 0
- [x] `plans/README.md` status row for 023 updated to DONE

## STOP conditions

Stop and report if:

- `NWConnection.receive` on CLI cannot avoid empty completions without polling
  (document Network.framework behavior observed).
- Removing sleeps breaks reconnection loop in `MCPService.run()` — investigate
  interaction before proceeding.
- Refactor requires extracting `StdioProxy` to a new target (out of scope unless
  minimal).

## Maintenance notes

- Keep CLI network reads aligned with `NWConnectionTransport` patterns when
  framing changes.
- Future shared transport module (tech-debt) should unify both paths.
