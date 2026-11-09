# Plan 029: Establish a green verification baseline for this fork

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 17d7c72..HEAD -- .github/workflows/ci.yml`
> If `ci.yml` changed since this plan was written, compare the "Current state"
> excerpt against the live file before proceeding; on a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P1
- **Effort**: S (the run) + unknown (whatever it surfaces)
- **Risk**: LOW to run; MED that it surfaces a backlog of failures
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `17d7c72`, 2026-08-07

## Why this matters

`gh run list -R cyberpapiii/iMCP` returns zero workflow runs. This fork is 67
commits ahead of `origin/main` and 0 behind (`git rev-list --left-right --count
origin/main...main` → `0 67`), and **none** of those 67 commits has ever been
through the lint, build, or test gate defined in `.github/workflows/ci.yml`.
That range includes the entire pairing and auth subsystem (plans 025–028), the
permissions UI, the Capture rewrite, and the CLI loopback fast path.

Every other plan in this directory names `xcodebuild` and `swift format lint`
as its verification backstop. Those commands are currently **unverified
assumptions** on this fork. Until one full gate run passes, no plan here can
honestly claim its verification gate means anything — a failure in a later plan
would be indistinguishable from a pre-existing failure. This plan makes the
baseline real, and it must land before any other plan in this batch.

## Current state

- `.github/workflows/ci.yml` — the gate. Runs on push and PR to `main`, on
  `macos-26` with Xcode 26.0, `timeout-minutes: 10`. Its four steps, in order:

```yaml
# .github/workflows/ci.yml:40-50
- name: Lint
  run: swift format lint --strict --recursive .

- name: Build
  run: xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build

- name: Test CLI
  run: xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"

- name: Test app
  run: xcodebuild test -scheme iMCP -destination "platform=macOS"
```

- Git remotes: `origin` → `https://github.com/mattt/iMCP.git` (upstream,
  read-only for this operator), `personal` →
  `https://github.com/cyberpapiii/iMCP.git` (where this fork pushes).
- The Xcode project treats warnings as errors, so a new warning fails the Build
  step, not just an error.
- `.swift-format` uses 4-space indentation, 120-column lines, and disables
  `AlwaysUseLowerCamelCase`.

**Convention note**: `-quiet` suppresses the `** BUILD SUCCEEDED **` marker.
For every `xcodebuild` command in this repo, **success is exit code 0** — check
`echo $?`, do not grep for a success string.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Lint (CI gate) | `swift format lint --strict --recursive .` | exit 0, no output |
| Format (write) | `swift format -i -r .` | exit 0 |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| CLI tests | `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` | exit 0, `TEST SUCCEEDED` |
| App tests | `xcodebuild test -scheme iMCP -destination "platform=macOS"` | exit 0, `TEST SUCCEEDED` |

## Scope

**In scope**:
- Running the four gate commands and recording their results.
- Minimal, surgical fixes to whatever they surface — formatting fixes from
  `swift format -i -r .`, compiler warnings promoted to errors, and genuinely
  broken tests.
- `plans/029-baseline-results.md` (create) — the recorded results.

**Out of scope** (do NOT touch, even though they look related):
- Any refactor beyond the minimum needed to make the gate pass. If a test
  fails because of a real product bug, **record it and STOP** — do not fix the
  bug here. Later plans in this directory (030–035) address specific known
  defects, and fixing one here creates a conflict with the plan that owns it.
- `.github/workflows/ci.yml` itself — the CI cache-key and Release-build
  improvements are deliberately deferred (see Maintenance notes).
- Enabling GitHub Actions on the fork — that is a repository-settings action
  in the GitHub web UI that only the operator can perform. Do not attempt it,
  and do not push commits to trigger it.

## Git workflow

- Branch: `advisor/029-verification-baseline`
- Commit style is conventional commits — see `git log --oneline`, e.g.
  `fix: clear stale config bookmarks and serialize camera captures`.
- Do NOT push or open a PR unless the operator asks.

## Steps

### Step 1: Record the lint result

Run the lint gate and capture its exact output.

```console
swift format lint --strict --recursive . ; echo "exit=$?"
```

If it exits non-zero, run `swift format -i -r .`, then re-run the lint command.
Formatting changes are safe and expected — that is exactly what the CI gate
enforces.

**Verify**: `swift format lint --strict --recursive . ; echo "exit=$?"` →
`exit=0` with no diagnostics.

### Step 2: Record the build result

```console
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```

Warnings are errors in this project. If the build fails on a warning, fix the
warning at its source — do not suppress it with a pragma or lower the warning
level.

Be aware: SourceKit reports spurious warnings such as "Cannot find type '___'
in scope" or "No such module '___'". Those are **editor-only** and do not
appear in `xcodebuild` output. Per `.cursor/rules/ignore-sourcekit-warnings.mdc`,
ignore them, and **never** install a Swift package to chase one.

**Verify**: the command above → `exit=0`.

### Step 3: Record the CLI test result

```console
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS" ; echo "exit=$?"
```

**Verify**: `exit=0` and the output contains `TEST SUCCEEDED`. Record the test
count.

### Step 4: Record the app test result

```console
xcodebuild test -scheme iMCP -destination "platform=macOS" ; echo "exit=$?"
```

Note: `iMCPTests/ServerNetworkManagerAuthTests.swift` writes to the **real**
`UserDefaults.standard` key `pairedClients` and restores it in `tearDown`. If
this run is interrupted, the operator's real paired-client list may be left
modified. Do not interrupt this step; if you must, report it explicitly so the
operator can re-pair. (Plan 032 fixes this test isolation problem.)

**Verify**: `exit=0` and the output contains `TEST SUCCEEDED`. Record the test
count.

### Step 5: Write the results file

Create `plans/029-baseline-results.md` recording, for each of the four gates:
the exact command, the exit code, the test count where applicable, and — if you
fixed anything — a one-line description of each fix and why it was minimal.

If any gate could not be made to pass, record the exact failure output verbatim
and mark that gate `FAILING`. A recorded failure is a successful outcome for
this plan; a silently-skipped gate is not.

**Verify**: `test -f plans/029-baseline-results.md ; echo "exit=$?"` → `exit=0`.

## Test plan

No new tests. This plan runs the existing suites and records the truth about
them. If Step 3 or Step 4 reveals a test that fails for a real reason, that
becomes a finding for the operator, not a fix in this plan.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` exits 0
- [ ] `xcodebuild test -scheme iMCP -destination "platform=macOS"` exits 0
- [ ] `plans/029-baseline-results.md` exists and records all four exit codes
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row for 029 updated

If a gate genuinely cannot pass, mark this plan `BLOCKED` in `plans/README.md`
with the failing gate named, and report — do not mark it DONE.

## STOP conditions

Stop and report back (do not improvise) if:

- A test fails for a reason that looks like a real product bug rather than a
  test-environment problem. Record the failure and stop; do not fix the
  product bug in this plan.
- The build fails in a way that needs a structural change (moving files between
  targets, changing access levels across modules, adding a dependency).
- Making the gate pass would require touching an out-of-scope file.
- `xcodebuild` cannot find the `iMCP` or `imcp-serverTests` scheme at all — that
  is a project-configuration problem the operator must resolve.
- The app test run leaves the real `pairedClients` UserDefaults key modified.

## Maintenance notes

For the human/agent who owns this after the change lands:

- **Operator action required, outside this plan**: enable GitHub Actions on
  `cyberpapiii/iMCP` (Settings → Actions → General → Allow all actions) and push
  once to get a real CI baseline. Until that happens, this local run is the only
  gate, and it must be run by hand before each plan is called done.
- Two CI improvements were deliberately deferred out of this plan and remain
  open findings:
  1. The DerivedData cache key is `hashFiles('**/Package.resolved')`, which
     changes only when dependencies do. `actions/cache` saves only on a key
     *miss*, so after the first run the cached DerivedData freezes permanently
     while still being restored. Fix by dropping DerivedData from the cached
     paths, or appending `-${{ github.run_id }}` to the key and relying on the
     existing `restore-keys` prefix.
  2. CI builds Debug only, and `WEATHERKIT_AVAILABLE` is set **only** in the app
     target's Release configuration (`iMCP.xcodeproj/project.pbxproj:852`). All
     222 lines of `App/Services/Weather.swift` and its two registry hooks
     (`App/Controllers/ServiceRegistry.swift:76-78` and `:242-252`) are
     therefore excluded from every build CI performs. A change breaking
     WeatherService compiles green today. Fix by adding a Release build-only
     step to CI.
- A reviewer should scrutinize any fix made in Step 1 or 2 for scope creep —
  this plan's fixes should be formatting and warnings only.
