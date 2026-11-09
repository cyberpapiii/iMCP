# Plan 030: Add the three orphaned test files to the `iMCPTests` target

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 17d7c72..HEAD -- iMCP.xcodeproj/project.pbxproj iMCPTests/`
> If any of those changed since this plan was written, compare the "Current
> state" excerpts against the live files before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW (worst case: a never-run test fails and reveals a real regression — that is the point)
- **Depends on**: plans/029-verification-baseline.md
- **Category**: tests
- **Planned at**: commit `17d7c72`, 2026-08-07

## Why this matters

Three test files exist on disk in `iMCPTests/` but have **no reference anywhere**
in `iMCP.xcodeproj/project.pbxproj`. They have never been compiled and have
never run — not locally, not in CI. Verify for yourself:

```console
for f in PairedClientStoreTests PlaceNameCacheTests ToolErrorSanitizationTests; do
  printf '%s: ' "$f"; grep -c "$f" iMCP.xcodeproj/project.pbxproj
done
# each prints 0
```

Two of the three are the deliverables of work recorded as **DONE** in
`plans/README.md`:

- `PlaceNameCacheTests.swift` — the LRU-cap regression test from the
  `advisor/024-reliability-backlog` batch (README row: "geocode LRU cap
  (`PlaceNameCache`, 512 entries)").
- `ToolErrorSanitizationTests.swift` — covers `sanitizedToolErrorMessage` in
  `App/Controllers/ToolErrorResponse.swift`, the function that keeps raw
  internal error text out of MCP responses (plan 019, marked DONE at `a70d79c`).
- `PairedClientStoreTests.swift` — the only coverage of the paired-client trust
  store that the Settings UI writes to (plan 025, marked DONE at `f463e8c`).

So the repo's status table currently claims coverage that does not exist. The
files were written, reviewed, and committed — they were simply never wired into
the target, and nothing about the build surfaces that.

The root cause will recur: the `iMCPTests` and `imcp-serverTests` targets list
their sources **by hand**, while the `iMCP` and `imcp-server` targets use
`PBXFileSystemSynchronizedRootGroup` (which picks up files on disk
automatically). Every future test file added to `iMCPTests/` can be silently
excluded the same way. Step 3 addresses that.

## Current state

- `iMCPTests/PairedClientStoreTests.swift`, `iMCPTests/PlaceNameCacheTests.swift`,
  `iMCPTests/ToolErrorSanitizationTests.swift` — exist on disk, unreferenced.
- The production symbols they test all exist, so the files should compile as
  written: `App/Controllers/PairedClientStore.swift`,
  `App/Controllers/ToolErrorResponse.swift` (`sanitizedToolErrorMessage`), and
  the `PlaceNameCache` used by the Photos service.
- `iMCP.xcodeproj/project.pbxproj:459-480` — the `iMCPTests` Sources build
  phase, listing 16 files by hand. Note the malformed whitespace on the last
  entry, which you should not replicate:

```
/* iMCP.xcodeproj/project.pbxproj:459-480 (abridged) */
		A01400052E00000000000005 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A01400032E00000000000003 /* ClaudeDesktopConfigTests.swift in Sources */,
				...
				B02700030000000000000003 /* ConnectionApprovalPairingTests.swift in Sources */,
				B0CT022012E00000000000001 /* CallToolDispatchTests.swift in Sources */,			);
			runOnlyForDeploymentPostprocessing = 0;
		};
```

- The three-part pattern each wired test file follows. `ConnectionApprovalQueueTests.swift`
  is the exemplar — **match it exactly**:

```
/* 1. PBXBuildFile, project.pbxproj:10 */
		B0CA02101000000000000001 /* ConnectionApprovalQueueTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = B0CA02102000000000000002 /* ConnectionApprovalQueueTests.swift */; };

/* 2. PBXFileReference, project.pbxproj:105 */
		B0CA02102000000000000002 /* ConnectionApprovalQueueTests.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = ConnectionApprovalQueueTests.swift; sourceTree = "<group>"; };

/* 3. group membership, project.pbxproj:210 */
				B0CA02102000000000000002 /* ConnectionApprovalQueueTests.swift */,

/* 4. Sources build phase, project.pbxproj:471 */
				B0CA02101000000000000001 /* ConnectionApprovalQueueTests.swift in Sources */,
```

Every wired test file needs **all four** entries. The two 24-character hex IDs
per file must be unique across the whole project file.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| App tests | `xcodebuild test -scheme iMCP -destination "platform=macOS"` | exit 0, `TEST SUCCEEDED` |
| CLI tests | `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` | exit 0, `TEST SUCCEEDED` |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

`-quiet` suppresses the success marker — **success is exit code 0**.

## Scope

**In scope** (the only files you should modify):
- `iMCP.xcodeproj/project.pbxproj`
- The three test files, **only** if they fail to compile — and only minimal
  fixes to make them compile against current production symbols.

**Out of scope** (do NOT touch, even though they look related):
- Any production source file under `App/`. If a newly-running test fails
  because the production code is wrong, **STOP and report** — do not fix the
  product. That is a finding for the operator.
- `CLITests/` and the `imcp-serverTests` target — its four source files are
  correctly wired already.
- Splitting `iMCPTests/ClaudeDesktopConfigTests.swift` (which contains five
  unrelated `XCTestCase` classes). Real problem, separate plan.
- Re-parenting `iMCPTests` to a synchronized group in this plan — see Step 3,
  which deliberately only *documents* the hazard.

## Git workflow

- Branch: `advisor/030-wire-orphaned-tests`
- Conventional commits, e.g. `test: wire orphaned iMCPTests files into the target`.
- Do NOT push or open a PR unless the operator asks.

## Steps

### Step 1: Add the three files to the project

For **each** of `PairedClientStoreTests.swift`, `PlaceNameCacheTests.swift`, and
`ToolErrorSanitizationTests.swift`, add all four entries shown in "Current
state", using the `ConnectionApprovalQueueTests.swift` block as the structural
template.

Use these IDs — they are checked-unique against the current project file:

| File | PBXBuildFile ID | PBXFileReference ID |
|------|-----------------|---------------------|
| `PairedClientStoreTests.swift` | `B03000010000000000000001` | `B03000020000000000000002` |
| `PlaceNameCacheTests.swift` | `B03000030000000000000003` | `B03000040000000000000004` |
| `ToolErrorSanitizationTests.swift` | `B03000050000000000000005` | `B03000060000000000000006` |

Before editing, confirm they are still unused:

```console
grep -c "B030000" iMCP.xcodeproj/project.pbxproj   # expect 0
```

Place each new entry adjacent to the existing `ConnectionApprovalQueueTests`
entries in the same four sections, so the file stays readable. While editing the
Sources build phase, fix the malformed last line noted in "Current state" so each
entry sits on its own line ending in `,`.

**Verify**:
```console
for f in PairedClientStoreTests PlaceNameCacheTests ToolErrorSanitizationTests; do
  printf '%s: ' "$f"; grep -c "$f" iMCP.xcodeproj/project.pbxproj
done
```
→ each prints `4`.

### Step 2: Build and run the app tests

```console
xcodebuild test -scheme iMCP -destination "platform=macOS" ; echo "exit=$?"
```

Three outcomes, and they are handled differently:

1. **Everything passes** — proceed to Step 3.
2. **A test fails to compile** because it references a symbol that has been
   renamed or has different access control. This is in scope: make the minimal
   change to the *test* so it compiles against current production code. If the
   production symbol no longer exists at all, STOP and report.
3. **A test compiles and fails an assertion.** STOP and report. This means a
   real regression has been sitting undetected in code marked DONE — exactly
   what this plan exists to surface. Record the failing test name and the
   assertion output verbatim. Do not fix the production code.

Record the new total test count and compare it against the count recorded in
`plans/029-baseline-results.md`; it must increase.

**Verify**: `exit=0`, output contains `TEST SUCCEEDED`, and the test count is
higher than the 029 baseline.

### Step 3: Document the hand-maintained-target hazard

The next test file added to `iMCPTests/` can be silently excluded the same way.
Add a short comment block to `plans/README.md` — in the "Ground rules for every
plan" section — stating:

> When adding a file to `iMCPTests/` or `CLITests/`, you must also add it to the
> target in `iMCP.xcodeproj/project.pbxproj` (four entries: `PBXBuildFile`,
> `PBXFileReference`, group membership, Sources build phase). Unlike the `iMCP`
> and `imcp-server` targets, the test targets do **not** use synchronized file
> groups, so a file on disk that is not listed simply never runs. Verify with
> `grep -c <BaseName> iMCP.xcodeproj/project.pbxproj` → expect `4`.

Converting the test targets to `PBXFileSystemSynchronizedRootGroup` would fix
this properly but is a riskier project-file change; it is deliberately deferred
(see Maintenance notes).

**Verify**: `grep -c "synchronized file groups" plans/README.md` → `1`.

### Step 4: Run the full gate

```console
swift format -i -r .
swift format lint --strict --recursive . ; echo "exit=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS" ; echo "exit=$?"
xcodebuild test -scheme iMCP -destination "platform=macOS" ; echo "exit=$?"
```

**Verify**: all four print `exit=0`.

## Test plan

No new tests are written by this plan — it makes 20 already-written assertions
across 3 suites actually execute. The verification is that the app-test count
increases relative to the `plans/029-baseline-results.md` baseline and the suite
still passes.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c PairedClientStoreTests iMCP.xcodeproj/project.pbxproj` → `4`
- [ ] `grep -c PlaceNameCacheTests iMCP.xcodeproj/project.pbxproj` → `4`
- [ ] `grep -c ToolErrorSanitizationTests iMCP.xcodeproj/project.pbxproj` → `4`
- [ ] `xcodebuild test -scheme iMCP -destination "platform=macOS"` exits 0
- [ ] `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` exits 0
- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] App-test count is strictly greater than the count in `plans/029-baseline-results.md`
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row for 030 updated

## STOP conditions

Stop and report back (do not improvise) if:

- A newly-wired test **compiles and fails an assertion**. Report the test name
  and assertion output; do not modify production code to make it pass.
- A test references a production symbol that no longer exists.
- The project file fails to parse after your edit (`xcodebuild` reports a
  project-format error). Revert with
  `git checkout iMCP.xcodeproj/project.pbxproj` and report — a corrupted
  `project.pbxproj` blocks all other work in this repo.
- Any of the three chosen IDs turns out to collide (the Step 1 `grep -c
  "B030000"` returns non-zero before your edit).

## Maintenance notes

For the human/agent who owns this code after the change lands:

- **A reviewer should check** that the four-entry pattern is complete and
  consistent for each file, and that no existing entry was disturbed. The
  cheapest review is the `grep -c … → 4` check per file plus a clean test run.
- **Deferred follow-up**: convert `iMCPTests` and `CLITests` to
  `PBXFileSystemSynchronizedRootGroup`, matching the `iMCP` and `imcp-server`
  targets, so disk contents and target membership can never diverge again. That
  is a larger project-file change deserving its own plan and its own review.
- **Related open finding, not fixed here**: `iMCPTests/ClaudeDesktopConfigTests.swift`
  holds five unrelated `XCTestCase` classes (`ClaudeDesktopConfigTests`,
  `ClaudeDesktopBookmarkPolicyTests`, `CameraPhotoCaptureGateTests`,
  `ServiceFixesTests`, `ToolResultTests`). It has become the test junk drawer,
  which is likely why the Capture rewrite added no tests — its only existing
  coverage is buried there. Splitting it needs its own plan (and each new file
  will need the Step 1 treatment).
