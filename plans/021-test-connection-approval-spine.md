# Plan 021: Test connection approval queue and tool gating

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 5caccce..HEAD -- App/Controllers/ServerController.swift App/Controllers/ServerNetworkManager.swift iMCPTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none (complements plan 020; no hard dependency)
- **Category**: tests
- **Planned at**: commit `5caccce`, 2026-07-06
- **Executed at**: commit `40653ea`, branch `advisor/021-test-connection-approval-spine`
- **Result**: DONE

## Why this matters

The connection approval path is iMCP's primary trust boundary. Commit
`7648816` fixed approval-window reentrancy when multiple clients queue (Allow
on the first prompt silently denied the second). That bug was caught by review,
not CI — only `testApprovalForUnregisteredConnectionIsIgnored` in
`ClaudeDesktopConfigTests.swift` touches `ServerNetworkManager`, and nothing
tests the approval queue state machine in `ServerController`. Automated
characterization here compounds: every future change to approval, gating, or
connection teardown gets a safety net.

## Current state

**Approval queue** — `App/Controllers/ServerController.swift:25-34`, `:132-200`:

- `activeApproval` + `queuedApprovals` serialize prompts.
- `presentNextApprovalIfNeeded()` defers window presentation one `Task` turn
  (`:142-162`) to avoid reentrancy when finishing the previous window.
- `finishActiveApproval` ignores stale callbacks (`:186-190`).
- `cancelApproval(for:)` denies active or queued requests when a connection is
  removed (`:167-183`).

**Tool gating** — `App/Controllers/ServerNetworkManager.swift:333-336`,
`:362-367`:

- `ListTools` returns empty tools when `!isConnectionApproved(connectionID)`.
- `CallTool` returns `"Tool call rejected: connection not approved"` with
  `isError: true`.

**Existing test** — `iMCPTests/ClaudeDesktopConfigTests.swift:131-145`:

```swift
func testApprovalForUnregisteredConnectionIsIgnored() async {
    let manager = ServerNetworkManager()
    let connectionID = UUID()
    await manager.markConnectionApproved(connectionID)
    var isApproved = await manager.isConnectionApproved(connectionID)
    XCTAssertFalse(isApproved)
    ...
}
```

Conventions: `@testable import iMCP`, `XCTestCase`, async tests where needed.
Pure helpers extracted for prior plans live in service files with tests in
`iMCPTests/*ServiceTests.swift` — follow that pattern.

Repo commands:

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| App tests | `xcodebuild test -scheme iMCP -destination "platform=macOS"` | exit 0 |
| Format lint | `swift format lint --strict --recursive .` | exit 0 |

## Scope

**In scope**:

- `App/Controllers/ConnectionApprovalQueue.swift` (create — extracted queue logic)
- `App/Controllers/ServerController.swift` (delegate to queue)
- `App/Controllers/ServerNetworkManager.swift` (tests only unless a package-visible test seam is required)
- `iMCPTests/ConnectionApprovalQueueTests.swift` (create)
- `iMCPTests/ServerNetworkManagerGatingTests.swift` (create)
- `iMCP.xcodeproj/project.pbxproj` (add files to targets if needed)

**Out of scope**:

- `ConnectionApprovalWindowController` / SwiftUI views (no window tests)
- MCP SDK integration tests with real `NWConnection`
- Approval TTL / auto-deny (deferred product decision)
- `MCPConnectionManager` health-monitor cancellation

## Git workflow

- Branch: `advisor/021-test-connection-approval-spine`
- Commit style: `test: characterize approval queue and tool gating`
- Do NOT push or open a PR unless the operator asks.

## Steps

### Step 1: Extract `ConnectionApprovalQueue`

Create `App/Controllers/ConnectionApprovalQueue.swift` with a `@MainActor`
type that owns:

```swift
struct ConnectionApprovalRequest: Equatable {
    let connectionID: UUID
    let clientName: String
}

@MainActor
final class ConnectionApprovalQueue {
    private(set) var active: ConnectionApprovalRequest?
    private(set) var queued: [ConnectionApprovalRequest] = []

    func enqueue(connectionID: UUID, clientName: String) -> EnqueueResult
    func finishActive(connectionID: UUID, approved: Bool) -> FinishResult
    func cancel(connectionID: UUID) -> CancelResult
    func dequeueNext() -> ConnectionApprovalRequest?
}
```

Define small `EnqueueResult` / `FinishResult` / `CancelResult` enums that
encode what the UI layer must do (e.g. `.presentNext`, `.resumeApproved`,
`.resumeDenied`, `.ignoredStaleCallback`) — **without** importing AppKit.

Move the state transitions from `ServerController`'s private methods into this
type:

| Operation | Expected behavior to preserve |
|-----------|--------------------------------|
| Enqueue while idle | becomes `active` |
| Enqueue while busy | appends to `queued` |
| Finish active with approve/deny | clears `active`, returns resume action |
| Finish with wrong ID | `.ignoredStaleCallback` |
| Cancel active ID | clears active, resumes deny, may return `.presentNext` |
| Cancel queued ID | removes from queue, resumes deny |
| Dequeue next | pops first queued into `active` |

Refactor `ServerController` to call the queue; keep window presentation in
`ServerController` (deferred `Task` + `approvalWindowController` unchanged).

**Verify**: `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` → exit 0.

### Step 2: Queue unit tests

Create `iMCPTests/ConnectionApprovalQueueTests.swift` with `@MainActor` tests:

1. **`testSecondClientQueuesWhileFirstActive`** — enqueue A, enqueue B →
   `active == A`, `queued == [B]`.
2. **`testApprovingActivePresentsNext`** — enqueue A, B; finish A approved;
   dequeueNext → B becomes active; queue empty.
3. **`testStaleFinishIgnored`** — enqueue A; finish with wrong UUID → active
   still A; no resume action.
4. **`testCancelActiveDeniesAndPresentsNext`** — A active, B queued; cancel A →
   A denied, B becomes active.
5. **`testCancelQueuedDeniesWithoutChangingActive`** — A active, B queued;
   cancel B → B denied, A still active.
6. **`testReentrancyRegression7648816`** — simulate: enqueue A, enqueue B,
   finish A approved, immediately verify B is eligible for presentation **before**
   any window callback runs (dequeueNext or enqueue result exposes B as next
   active after finish).

Use injected UUIDs and fixed client names — no UI.

**Verify**:

```console
xcodebuild test -scheme iMCP -destination "platform=macOS" -only-testing:iMCPTests/ConnectionApprovalQueueTests
```

→ exit 0, ≥6 tests pass.

### Step 3: ServerNetworkManager gating tests

Create `iMCPTests/ServerNetworkManagerGatingTests.swift`:

Because full MCP handler registration requires an `MCP.Server` instance, test
the **approval flag semantics** that handlers rely on:

1. **`testUnapprovedConnectionCannotBeMarkedApprovedWithoutRegistration`** —
   extend/replace logic from existing test: random UUID stays unapproved.
2. **`testApprovedConnectionIDTrackedUntilRemoval`** — if the manager exposes
   a test seam, register a fake connection ID through package-internal test
   hooks; mark approved; assert `isConnectionApproved` true; `removeConnection`
   → false.

If handlers cannot be invoked without a live server, add `@testable` package-internal
methods on `ServerNetworkManager`:

```swift
#if DEBUG
func testMarkConnectionApprovedForTesting(_ id: UUID) { ... }
#endif
```

**Only if necessary** — prefer using existing public methods
(`markConnectionApproved`, `removeConnection`, `isConnectionApproved`) if a
registration path exists without Network.framework.

Optional stretch (same file, if harness is cheap):

3. **`testListToolsReturnsEmptyWhenUnapproved`** — requires MCP server mock;
   skip with `throw XCTSkip` and a TODO if too heavy — **not required for done**.

Minimum bar: approval flag lifecycle tests (items 1–2).

**Verify**:

```console
xcodebuild test -scheme iMCP -destination "platform=macOS" -only-testing:iMCPTests/ServerNetworkManagerGatingTests
```

→ exit 0.

### Step 4: Format and full app test suite

```console
swift format -i -r .
swift format lint --strict --recursive .
xcodebuild test -scheme iMCP -destination "platform=macOS"
```

All exit 0.

## Test plan

- `ConnectionApprovalQueueTests` — state machine + 7648816 regression.
- `ServerNetworkManagerGatingTests` — approval ID lifecycle.
- Existing `ClaudeDesktopConfigTests` / service tests remain green.

## Done criteria

- [x] `ConnectionApprovalQueue` extracted; `ServerController` delegates to it
- [x] ≥6 queue tests pass
- [x] Gating tests pass (minimum approval lifecycle)
- [x] `xcodebuild test -scheme iMCP -destination "platform=macOS"` → exit 0
- [x] `swift format lint --strict --recursive .` → exit 0
- [x] No AppKit in `ConnectionApprovalQueue.swift`
- [x] `plans/README.md` status row for 021 updated to DONE

## STOP conditions

Stop and report if:

- Approval queue structure in `ServerController` differs materially (already
  extracted elsewhere).
- Extracting the queue requires rewriting MCP approval bridging — scope creep.
- Tests require `#if DEBUG` hooks in release paths that violate repo policy.

## Maintenance notes

- Any UI change to approval flow must update queue tests first.
- `presentNextApprovalIfNeeded`'s deferred `Task` stays in `ServerController` —
  queue tests cover state; UI timing stays manual/integration.
- When approval TTL lands (deferred finding), extend `ConnectionApprovalQueue`
  with timeout tokens — tests in this file become the harness.
