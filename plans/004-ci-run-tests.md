# Plan 004: CI runs the existing test suite

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- .github/workflows/ci.yml`
> If `.github/workflows/ci.yml` changed since this plan was written, compare the
> "Current state" excerpt against the live file before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

The repo has exactly one regression test suite —
`CLITests/ServiceGroupConfigurationTests.swift` — and it guards a *fatal crash*
that already shipped once (the #166 Bonjour-disconnect crash; the production fix
in `CLI/main.swift:622-638` is explicitly load-bearing and documented as such).
CI currently only lints formatting and builds; it never runs the tests. That
means the one automated guard the project has against reintroducing a known
crash provides no protection in CI — a dependency bump (e.g. swift-service-
lifecycle changing its default termination behavior) could reintroduce the crash
and pass CI green. After this plan, CI runs the test scheme on every push and PR.

## Current state

- `.github/workflows/ci.yml` — the CI workflow. Steps today (`ci.yml:38-47`):

```yaml
            - name: Lint
              run: swift format lint --strict --recursive .

            - name: Build
              run: xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build
```

- A shared test scheme exists:
  `iMCP.xcodeproj/xcshareddata/xcschemes/imcp-serverTests.xcscheme`
  (testable target `imcp-serverTests.xctest`).
- The test file: `CLITests/ServiceGroupConfigurationTests.swift` (3 tests).

The runner is `macos-26` with `Xcode_26.0` (`ci.yml:12-24`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| List schemes | `xcodebuild -list -project iMCP.xcodeproj` | includes `imcp-serverTests` and `iMCP` |
| Run tests locally | `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` | `** TEST SUCCEEDED **` |

Run the local test command first to confirm the exact scheme name and that the
suite passes on this machine before wiring CI.

## Scope

**In scope**:
- `.github/workflows/ci.yml`

**Out of scope**:
- The test files themselves — adding new tests is plan 014, not this one.
- The build step — leave it unchanged; the test step is additive.
- `iMCP.xcodeproj` scheme files — do not modify schemes.

## Git workflow

- Branch: `advisor/004-ci-run-tests`
- Single commit (e.g. "Run test scheme in CI").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Confirm the scheme name and that tests pass locally

Run `xcodebuild -list -project iMCP.xcodeproj` and confirm the test scheme is
named `imcp-serverTests`. Then run:

`xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"`

**Verify**: output ends with `** TEST SUCCEEDED **`. If the scheme name differs,
use the actual name in Step 2 and note it.

### Step 2: Add a Test step to CI

In `.github/workflows/ci.yml`, add a step immediately after the Build step,
using the same indentation as the surrounding steps:

```yaml
            - name: Test
              run: xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"
```

Keep `-quiet` off for the test step (test failures are easier to read with full
output), or add it to match Build style — either is acceptable; match whichever
the operator prefers if stated.

**Verify**: `grep -n "xcodebuild test" .github/workflows/ci.yml` → shows the new
step. YAML is well-formed: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"` exits 0 (if `pyyaml` is unavailable, skip and rely on the grep + visual indentation check).

## Test plan

The change *is* CI configuration. Verification:
- Local `xcodebuild test` passes (Step 1).
- YAML parses and the new step is present (Step 2).
- Note in your report that final validation happens when CI runs on the PR.

## Done criteria

ALL must hold:

- [ ] Local `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` prints `** TEST SUCCEEDED **`
- [ ] `.github/workflows/ci.yml` contains a Test step invoking `xcodebuild test`
- [ ] The YAML is valid and indentation matches the existing steps
- [ ] No files outside `.github/workflows/ci.yml` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- `xcodebuild test` fails locally — the suite is red before your change; report
  the failure rather than wiring CI to a failing suite.
- The test scheme does not exist or is not shared (not in
  `xcodeproj/xcshareddata/xcschemes/`) — CI can't run an unshared scheme; report.
- The build/test requires signing or a provisioning profile in CI that isn't
  configured (the project builds Debug without provisioning per commit
  `deff5dd`; if tests demand more, report).

## Maintenance notes

- Once plan 014 adds the App-side test target (config-merge tests), add its
  scheme to this Test step (or a second Test step) so that suite also runs in CI.
- Reviewer should confirm the test step actually gates the workflow (a failing
  test fails the job), not just runs informationally.
