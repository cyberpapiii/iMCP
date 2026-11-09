# Plan 013: Split `ServerController.swift` into focused files (and fix the escaped-log bug)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- App/Controllers/ServerController.swift`
> If `App/Controllers/ServerController.swift` changed since this plan was written,
> re-read it fully before proceeding; the line references below are a map, not a
> contract.

## Status

- **Priority**: P3
- **Effort**: L
- **Risk**: MED
- **Depends on**: **do 009 first** (concurrency fix in place before moving code).
  Coordinate with 012 (see ordering).
- **Category**: tech-debt / architecture
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

`ServerController.swift` is ~1031 lines and holds at least four distinct
responsibilities in one file: the `@MainActor` UI/approval controller, the MCP
connection manager actor, the Bonjour network-discovery actor, and the
`ServerNetworkManager` actor that implements every MCP handler. It is the
highest-churn file in the repo and the origin of two recent shipped regressions
(#150 config overwrite, #166 disconnect crash). A single god-file this size makes
every change high-risk (broad merge surface, hard to review, easy to touch
unrelated state) and makes targeted testing nearly impossible. Splitting it along
the isolation boundaries that already exist (each type is already a separate
`actor`/`class`) is low-semantic-risk and makes future fixes reviewable. This
plan is a **pure structural move** plus one trivial, self-contained log-string
bug fix — no behavior changes.

## Current state

- `App/Controllers/ServerController.swift` — one file containing (approximate
  ranges at commit `b84f266`; re-read to confirm before moving):
  - `ServiceConfig`, `ServiceRegistry` and related config types — `~50-152`
  - `@MainActor final class ServerController` (UI state, approval, trust) — `~154-415`
  - `actor MCPConnectionManager` — `~420-534`
  - `actor NetworkDiscoveryManager` — `~537-623`
  - `actor ServerNetworkManager` (MCP handlers: initialize, ListTools, CallTool,
    connection lifecycle) — `~625-1031`

- **Escaped-log bug** (fix as part of this move), `ServerController.swift:696`
  and `:709`:

```swift
logger.info("Listener state changed to \\(listenerState)")   // prints the literal "\(listenerState)"
```

The doubled backslash means the string interpolation is escaped, so the log emits
the literal text `\(listenerState)` instead of the value. The fix is a single
backslash: `"...changed to \(listenerState)"`.

- `removedConnections` (declared `~632`, cleared only in `stop()` `~775-797`)
  grows unbounded during a long session. This plan does **not** fix that (it's a
  behavior change); just preserve it and note it (see Maintenance).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format (write) | `swift format -i -r .` | exit 0 |
| Format lint (CI gate) | `swift format lint --strict --recursive .` | exit 0, no output |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | `** BUILD SUCCEEDED **` |
| Run tests | `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` | `** TEST SUCCEEDED **` |

**Xcode project note**: adding a new `.swift` file requires it to be a member of
the `iMCP` app target. This project uses a `.xcodeproj` (not SPM for the app), so
new files must be added to the target's "Compile Sources" build phase. If you
cannot reliably edit `project.pbxproj` to register new files (it is easy to
corrupt), see STOP conditions — a same-file `// MARK:` reorganization is the
fallback.

## Scope

**In scope**:
- `App/Controllers/ServerController.swift` (source of the move)
- New files under `App/Controllers/` (destinations)
- `iMCP.xcodeproj/project.pbxproj` (only to register the new files in the app target)

**Out of scope**:
- Any behavior change. Types, access levels, isolation, and method bodies move
  **verbatim**. The only content edit permitted is the escaped-log single-backslash fix.
- `removedConnections` unbounded-growth fix — do not change it here.
- The enablement-read fix — that's plan 009; if 009 hasn't landed, do it first.

## Ordering note

Shares this file with plans 009 and 012. Recommended global order:
**009 (race fix) → 013 (this split) → 012 (cache)**. Doing 013 before 009 means
moving code you're about to change; doing 012 before 013 means caching code
you're about to move. If the operator insists on a different order, adapt, but
prefer this one.

## Git workflow

- Branch: `advisor/013-split-servercontroller`
- Commit the escaped-log fix separately first (tiny, obviously-correct), then the
  move as one or a few commits. Short imperative messages.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fix the escaped-log bug (isolated, first)

Change the doubled backslash to a single backslash at `ServerController.swift:696`
and `:709` so `listenerState` interpolates. Search for any other `\\(` in this
file and fix those that are clearly meant to interpolate (confirm each is a log
string, not an intentional literal).

**Verify**: `grep -n '\\\\(' App/Controllers/ServerController.swift` → no
unintended escaped interpolations remain in log strings. Build succeeds.

### Step 2: Plan the file split (no code moved yet)

Decide the destination files, one responsibility each. Suggested:
- `App/Controllers/ServerController.swift` — keeps `@MainActor ServerController`
  (UI/approval/trust) only.
- `App/Controllers/ServiceRegistry.swift` — `ServiceConfig`, `ServiceRegistry`, config types.
- `App/Controllers/MCPConnectionManager.swift` — the `MCPConnectionManager` actor.
- `App/Controllers/NetworkDiscoveryManager.swift` — the `NetworkDiscoveryManager` actor.
- `App/Controllers/ServerNetworkManager.swift` — the `ServerNetworkManager` actor + MCP handlers.

Record the mapping in your report before moving anything.

**Verify**: you have a written type→file map.

### Step 3: Move types verbatim, one file at a time, building after each

For each destination file: create it, move the type(s) **unchanged** (including
imports the type needs), register the file in the `iMCP` target, and build. Do one
type per build cycle so a break is localized.

- Keep access levels exactly as they were (types were same-file `internal`/
  `private`; moving to another file may require promoting a `private` to
  `internal` or `fileprivate`→`internal` **only** where the compiler demands it —
  note every such promotion in your report; do not broaden more than required).
- Do not reorder or rename anything.

**Verify after each move**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`.

### Step 4: Format, build, test

Run `swift format -i -r .`, then build, then the test scheme.

**Verify**: build `** BUILD SUCCEEDED **`; `xcodebuild test ...` `** TEST SUCCEEDED **`
(the existing CLI tests must still pass — they exercise the CLI, but a green run
confirms nothing structural broke); `swift format lint --strict --recursive .` exits 0.

## Test plan

This is a behavior-preserving refactor; the guardrail is "compiles + existing
tests pass + no diff in behavior."
- The existing `CLITests` suite must still pass.
- No new tests are required by this plan (the split enables future tests; writing
  them is plan 014 and beyond).
- Manual smoke (record results): if you can run the app, connect a client and
  confirm initialize/approval, `ListTools`, and one `CallTool` all still work —
  proving the moved actors still wire together.

## Done criteria

ALL must hold:

- [ ] The escaped-log interpolation is fixed (single backslash) and verified by grep
- [ ] `ServerController.swift` no longer contains all five responsibilities;
      each moved type lives in its own file under `App/Controllers/`
- [ ] Every new file is a member of the `iMCP` app target (it compiles)
- [ ] No method body changed except the log-string fix (diff is pure move +
      minimal access-level promotions, each noted)
- [ ] `xcodebuild ... build` prints `** BUILD SUCCEEDED **`
- [ ] `xcodebuild test -scheme imcp-serverTests ...` prints `** TEST SUCCEEDED **`
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- You cannot safely register new files in `iMCP.xcodeproj/project.pbxproj`
  without risking corruption. **Fallback**: instead of new files, reorganize
  within `ServerController.swift` using clear `// MARK: -` sections per
  responsibility and extract only the config types (`ServiceRegistry.swift`) if
  even one file can be added safely. A well-sectioned single file is a smaller
  but real improvement; ship that and report the limitation.
- Moving a type requires broadening access far beyond `internal`, or reveals
  hidden coupling (a `private` member reached across types) that can't be
  resolved by a mechanical move — report the coupling; do not redesign it here.
- The existing tests fail after the move — report; a behavior-preserving move
  must not turn them red.

## Maintenance notes

- After the split, plans 009 and 012 land in the smaller `ServerNetworkManager.swift`.
- `removedConnections` unbounded growth (`~632`, cleared only in `stop()`) is a
  real leak but a behavior change; file it as a follow-up finding — do not fix in
  this structural plan.
- Reviewer should diff with `--color-moved` to confirm the change is a pure move
  plus the one log fix, and scrutinize every access-level promotion listed.
