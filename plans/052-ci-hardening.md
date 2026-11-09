# Plan 052: CI runs pinned actions, lints the scripts, and compiles Release

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- .github/workflows/ci.yml Scripts/ App/App.CI.entitlements`
> Changes under `Scripts/` and to `App/App.CI.entitlements` are expected
> (plans 050 and 051 land first and edit or delete scripts and entitlements).
> A change to `.github/workflows/ci.yml` is NOT expected: compare the "Current
> state" excerpt against the live file and treat a mismatch as a STOP
> condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (workflow and one script comment; no app code)
- **Depends on**: `plans/050-script-safety.md`, `plans/051-deletion-sweep.md`
  (shellcheck must run on the fixed scripts, and the orphan scripts must
  already be deleted so they are not linted)
- **Category**: security, dx
- **Planned at**: commit `8165d29`, 2026-10-12

## Why this matters

`.github/workflows/ci.yml` is the only gate between a pull request and `main`:
`Scripts/ship.sh` waits for it and then merges automatically. Today that gate
has three holes. It runs third-party actions by mutable tag (`@v6`, `@v5`), so
whoever can move that tag can run code in the gate. It never looks at the
3,000 lines of shell, Python and Node under `Scripts/`, which include the
release and install paths. And every `xcodebuild` in it uses
`-configuration Debug`, so code that only compiles in Release (16 `#if
DEBUG`/`#if WEATHERKIT_AVAILABLE` sites, including the only place the Weather
service is registered) is first compiled during a publish. After this plan the
gate runs only commit-pinned actions, fails on a script that does not parse or
lint, and fails on a Release compile error.

## Current state

Files:

- `.github/workflows/ci.yml` — the whole CI definition, one job (`build`), 83 lines.
- `Scripts/ship.sh` — the automated ship path; trusts every check on the PR.
- `Scripts/*.sh`, `Scripts/*.py`, `Scripts/*.mjs` — unlinted by CI.
- `App/App.CI.entitlements` — entitlements file CI substitutes because runners
  have no provisioning profile. Not edited by this plan.
- `iMCP.xcodeproj/project.pbxproj` — read only, for the facts below.

`.github/workflows/ci.yml` at `8165d29`, the lines this plan changes:

```yaml
 9  permissions:
10      contents: read
...
18  jobs:
19      build:
20          name: Build on macOS ${{ matrix.macos }} with Xcode ${{ matrix.xcode }}
21          runs-on: macos-${{ matrix.macos }}
22          env:
23              DEVELOPER_DIR: "/Applications/Xcode_${{ matrix.xcode }}.app/Contents/Developer"
24              # Runners have no signing certificate and no provisioning profile.
25              # Ad-hoc signing is still required for arm64 binaries to execute, so
26              # this pins the identity rather than disabling signing, and swaps in
27              # an entitlements file without the keychain access group, which a
28              # build with no profile is not authorized to claim.
29              SIGNING_OVERRIDES: >-
30                  CODE_SIGN_IDENTITY=-
31                  CODE_SIGN_STYLE=Manual
32                  DEVELOPMENT_TEAM=
33                  PROVISIONING_PROFILE_SPECIFIER=
34                  CODE_SIGN_ENTITLEMENTS=App/App.CI.entitlements
...
41          timeout-minutes: 10
42          steps:
43              - name: Checkout code
44                uses: actions/checkout@v6
...
50              - name: Cache resolved packages
51                uses: actions/cache@v5
...
58              - name: Cache build products
59                uses: actions/cache@v5
...
67              - name: Lint
68                run: swift format lint --strict --recursive .
...
72              - name: Build for testing
73                run: |
74                    xcodebuild -quiet build-for-testing -scheme iMCP \
75                      -configuration Debug -destination "platform=macOS" $SIGNING_OVERRIDES
76                    xcodebuild -quiet build-for-testing -scheme imcp-serverTests \
77                      -configuration Debug -destination "platform=macOS" $SIGNING_OVERRIDES
78
79              - name: Test CLI
80                run: xcodebuild test-without-building -scheme imcp-serverTests -configuration Debug -destination "platform=macOS" $SIGNING_OVERRIDES
81
82              - name: Test app
83                run: xcodebuild test-without-building -scheme iMCP -configuration Debug -destination "platform=macOS" $SIGNING_OVERRIDES
```

The file indents with 4 spaces per level. Keep that.

How `ship.sh` trusts CI (`Scripts/ship.sh:275-276`):

```bash
gh pr checks "${pr_url}" --repo "${repo}" --watch --fail-fast
gh pr merge "${pr_url}" --repo "${repo}" --merge --delete-branch
```

`gh pr checks --watch` waits for every check on the PR, so new jobs added by
this plan gate the merge automatically. `ship.sh` needs no edit.

Release-only code:

- `iMCP.xcodeproj/project.pbxproj:1045` (app target, Release only):
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "WEATHERKIT_AVAILABLE $(inherited)";`
- `App/Controllers/ServiceRegistry.swift:276` `#if WEATHERKIT_AVAILABLE` wraps
  the `ServiceDescriptor(name: "Weather", … service: WeatherService.shared …)`
  registration. Debug never compiles it.
- Release also sets `SWIFT_COMPILATION_MODE = wholemodule`
  (`project.pbxproj:914`) and does not set `ONLY_ACTIVE_ARCH`, so it builds
  both architectures. Expect it to be slower than the Debug build.
- The release path already builds exactly this way
  (`Scripts/release.sh:274`, defaults `SCHEME=iMCP`, `CONFIGURATION=Release`,
  `DESTINATION=platform=macOS`):
  `xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "${DESTINATION}" build`
- The `iMCP` scheme's build action contains the `iMCP` and `imcp-server`
  targets (`iMCP.xcodeproj/xcshareddata/xcschemes/iMCP.xcscheme:20,34`), so one
  `build` of that scheme compiles the app, the CLI and the app's embedded
  helper. Use `build`, not `build-for-testing`: test targets use `@testable
  import`, which Release does not support.
- Release signing settings differ from Debug: the `imcp-server` Release
  configuration has `"CODE_SIGN_IDENTITY[sdk=macosx*]" = "Developer ID Application"`
  and `"DEVELOPMENT_TEAM[sdk=macosx*]" = TTY35UM57S`
  (`project.pbxproj:1071,1075`). The Debug configuration has the same kind of
  SDK-conditional identity (`:1055`) and CI's unconditional
  `CODE_SIGN_IDENTITY=-` override already beats it, so the same
  `SIGNING_OVERRIDES` are expected to work for Release. Step 5 has the one
  permitted fallback if they do not.

Script lint, measured at `8165d29` with shellcheck 0.11.0 (read-only run, no
script executed):

```console
$ shellcheck -f gcc Scripts/*.sh
Scripts/find-my-people-bootstrap.sh:38:9: warning: Prefer mapfile or read -a to split command output (or quote to avoid splitting). [SC2207]
```

That is the only finding. The line is:

```bash
38    PIDS=($(/usr/bin/pgrep -x findmylocateagent))
```

Every `.py` parses and every `.mjs` passes `node --check` at `8165d29`.
Plans 050 and 051 will have changed this set by the time you run; Step 2
re-measures.

Conventions:

- Scripts start with `#!/usr/bin/env bash`; on macOS that can be bash 3.2,
  which has no `mapfile`. Do not introduce `mapfile` or `readarray`.
- Existing shellcheck disables are one line directly above the offending line
  (`Scripts/release.sh:449`: `# shellcheck disable=SC2046`). Match that, and
  add the reason on the same line after a second `#`.
- This repo is a fork. `origin` = `cyberpapiii/iMCP` is the only writable
  remote. `upstream` = `mattt/iMCP` must never receive a push or a PR. `gh pr
  create` in a fork defaults to the parent repository, so every `gh` command
  that writes must carry `--repo cyberpapiii/iMCP`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Shell lint | `shellcheck Scripts/*.sh` | exit 0, no output |
| Python parse | `PYTHONPYCACHEPREFIX="$(mktemp -d)" python3 -m py_compile Scripts/*.py` | exit 0, no output |
| Node parse | `for f in Scripts/*.mjs; do node --check "$f" \|\| echo "FAIL $f"; done` | no output |
| Workflow parses | `ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml"); puts "ok"'` | `ok` |
| Swift lint (unchanged gate) | `swift format lint --strict --recursive .` | exit 0 |
| Debug build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| Tests (only if a script edit worries you) | `Scripts/test.sh` | all pass |

Never run `xcodebuild test -scheme iMCP` directly (the always-on watchdog
relaunches the installed app and breaks the test host) and never `launchctl
bootout` the always-on agent. Do not execute any script under `Scripts/` other
than `Scripts/test.sh`; linting reads them, it does not run them.

`PYTHONPYCACHEPREFIX` keeps `py_compile` from writing `Scripts/__pycache__/`
into the working tree (`.gitignore` does not ignore it).

## Scope

**In scope** (the only files you may modify):

- `.github/workflows/ci.yml`
- `Scripts/*.sh` — only the minimum needed to make `shellcheck Scripts/*.sh`
  exit 0: a behaviour-preserving quoting fix, or a one-line scoped disable
  with a reason. Nothing else.
- `plans/README.md` — status row only.

**Out of scope** (do NOT touch):

- `Scripts/ship.sh`, `Scripts/release.sh`, `Scripts/install-local.sh` logic.
  Behavioural script fixes belong to plan 050.
- Deleting scripts. Plan 051 owns that. If an orphan listed there still
  exists, see STOP conditions.
- Any Swift source, `project.pbxproj`, or entitlements file. If the Release
  build does not compile, that is a finding to report, not something to fix
  here.
- Adding Dependabot, `actionlint`, a Release test run, or new matrix entries.
- Renaming the existing `build` job or changing its `name:`. Branch protection
  on `cyberpapiii/iMCP` may require that exact check name.
- Running `Scripts/install-local.sh`. Nothing in this plan changes the app.

## Git workflow

- Start from an up-to-date `main` (`git fetch origin && git switch -c
  advisor/052-ci-hardening origin/main`).
- Conventional commits, matching `git log` (e.g. `fix: bring Settings forward
  from the menu; stay quiet on relaunch`). Use two commits:
  1. `chore(scripts): make Scripts pass shellcheck` (omit if Step 2 needs no edit)
  2. `ci: pin actions, lint scripts, and build Release`
- Do NOT push or open a PR unless the operator instructs it. Step 6 is the
  only step that pushes and it is operator-gated.
- Never use `Scripts/ship.sh` for this plan: it merges and installs.

## Steps

### Step 1: Confirm the prerequisites landed

Run:

```bash
grep -nE '^\| *05[01] ' plans/README.md
ls Scripts
command -v shellcheck node python3 ruby gh
```

**Verify**: the rows for 050 and 051 both show `DONE`; `ls Scripts` does NOT
list `measure-runtime-efficiency.py`, `measure-mcp-client.sh`,
`bench-mcp-client.mjs` or `find-my-people-key.py` (plan 051 deletes them);
all five tools resolve to a path. Otherwise STOP.

### Step 2: Make the existing scripts pass the three checks

Run the three lint commands from the Commands table.

- Python and Node: expected clean. A failure means a script does not parse;
  STOP and report it (that is a plan 050 defect, not a lint nit).
- shellcheck: expected at most the one `SC2207` finding shown in "Current
  state". If it is still present, add exactly one line directly above
  `PIDS=($(/usr/bin/pgrep -x findmylocateagent))` in
  `Scripts/find-my-people-bootstrap.sh`, at the same indentation:

  ```bash
  # shellcheck disable=SC2207 # pgrep prints one numeric PID per line; splitting is intended and bash 3.2 has no mapfile
  ```

  Do not rewrite the line and do not run the script (it is part of the
  human-only Find My People bootstrap).
- Any other shellcheck finding: fix it only if the fix is a pure quoting
  change that cannot alter behaviour (e.g. `SC2086` on a variable that is
  never meant to split). Otherwise add a one-line scoped disable with a reason
  in the same form. Never add a file-wide disable and never pass `--exclude`
  or `--severity` in CI. More than five findings: STOP.

**Verify**:

```bash
shellcheck Scripts/*.sh; echo "exit $?"
git diff --stat -- Scripts
```

→ `exit 0` with no findings; the diff touches only `.sh` files and adds at
most a handful of lines. Commit (commit 1) if anything changed.

### Step 3: Look up the action commit SHAs (read-only; do not guess)

Run:

```bash
gh api repos/actions/checkout/commits/v6 --jq .sha
gh api repos/actions/cache/commits/v5 --jq .sha
```

Cross-check each against git itself, without `gh`:

```bash
git ls-remote https://github.com/actions/checkout 'refs/tags/v6' 'refs/tags/v6^{}'
git ls-remote https://github.com/actions/cache    'refs/tags/v5' 'refs/tags/v5^{}'
```

If a `^{}` line is printed, its SHA is the commit; otherwise the plain line's
SHA is. Then find the exact release each SHA is (for the comment):

```bash
git ls-remote --tags https://github.com/actions/checkout | grep <CHECKOUT_SHA>
git ls-remote --tags https://github.com/actions/cache    | grep <CACHE_SHA>
```

Pick the most specific tag printed (e.g. `v6.0.1` rather than `v6`); if only
the major tag matches, use it.

**Verify**: both SHAs are 40 lowercase hex characters
(`[[ "$sha" =~ ^[0-9a-f]{40}$ ]]`), and the `gh api` SHA equals the
`ls-remote` commit SHA for each action. If they differ, or either lookup
fails, STOP. Never type a SHA from memory or from this plan.

### Step 4: Compile Release locally once, before putting it in the gate

This tells you whether the new CI job will be red on arrival. It uses a
throwaway DerivedData so nothing else is disturbed, and it does not run or
install anything.

```bash
xcodebuild -quiet build -scheme iMCP -configuration Release \
  -destination "platform=macOS" -derivedDataPath "${TMPDIR%/}/imcp-052-release" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_ENTITLEMENTS=App/App.CI.entitlements
echo "exit $?"
```

**Verify**: `exit 0`. Note the wall-clock time for your report. Then
`rm -rf "${TMPDIR%/}/imcp-052-release"`.

If it fails: do not edit Swift. The local Xcode is 27 beta and CI is Xcode
26.0, so a failure may be a 27-only diagnostic (`ImplicitStrongCapture`,
`NoUseUnstructuredThrowingTask`) or a real Release-only error. Copy the first
20 `error:` lines into your report and STOP for the operator to decide.

### Step 5: Rewrite the workflow

Edit `.github/workflows/ci.yml` so that it has this shape. Lines marked
`(unchanged)` stay byte-for-byte as they are today, including their comments.
Replace `<CHECKOUT_SHA>`, `<CACHE_SHA>` and the `vX.Y.Z` comments with the
values from Step 3.

1. Move `SIGNING_OVERRIDES` and its five-line comment from `jobs.build.env`
   to a new workflow-level `env:` block placed after `concurrency:` and before
   `jobs:`, so both macOS jobs share one definition. `DEVELOPER_DIR` stays in
   `jobs.build.env` (it uses `matrix`, which is not available at workflow
   level).

   ```yaml
   env:
       # Runners have no signing certificate and no provisioning profile.
       # Ad-hoc signing is still required for arm64 binaries to execute, so
       # this pins the identity rather than disabling signing, and swaps in
       # an entitlements file without the keychain access group, which a
       # build with no profile is not authorized to claim.
       SIGNING_OVERRIDES: >-
           CODE_SIGN_IDENTITY=-
           CODE_SIGN_STYLE=Manual
           DEVELOPMENT_TEAM=
           PROVISIONING_PROFILE_SPECIFIER=
           CODE_SIGN_ENTITLEMENTS=App/App.CI.entitlements
   ```

2. In the `build` job, change only the three `uses:` lines and add
   `persist-credentials: false` to the checkout. Job key, `name:`, matrix,
   `timeout-minutes: 10`, cache keys and every `run:` stay unchanged.

   ```yaml
               - name: Checkout code
                 uses: actions/checkout@<CHECKOUT_SHA> # vX.Y.Z
                 with:
                     persist-credentials: false
   ...
               - name: Cache resolved packages
                 uses: actions/cache@<CACHE_SHA> # vX.Y.Z
   ...
               - name: Cache build products
                 uses: actions/cache@<CACHE_SHA> # vX.Y.Z
   ```

3. Append two jobs after `build`, at the same indentation as `build:`.

   ```yaml
       # Every other xcodebuild here is Debug. This is the only place code
       # behind `#if !DEBUG` or WEATHERKIT_AVAILABLE (Release-only, including
       # Weather service registration) is compiled before a publish. It is a
       # separate job because a whole-module, two-architecture build does not
       # fit in the test job's ten minutes.
       release-build:
           name: Release build on macOS 26 with Xcode 26.0
           runs-on: macos-26
           env:
               DEVELOPER_DIR: "/Applications/Xcode_26.0.app/Contents/Developer"
           timeout-minutes: 20
           steps:
               - name: Checkout code
                 uses: actions/checkout@<CHECKOUT_SHA> # vX.Y.Z
                 with:
                     persist-credentials: false

               - name: Cache resolved packages
                 uses: actions/cache@<CACHE_SHA> # vX.Y.Z
                 with:
                     path: ~/Library/Caches/org.swift.swiftpm
                     key: ${{ runner.os }}-xcode-26.0-spm-${{ hashFiles('**/Package.resolved') }}
                     restore-keys: |
                         ${{ runner.os }}-xcode-26.0-spm-

               - name: Cache build products
                 uses: actions/cache@<CACHE_SHA> # vX.Y.Z
                 with:
                     path: ~/Library/Developer/Xcode/DerivedData
                     key: ${{ runner.os }}-xcode-26.0-release-derived-${{ hashFiles('**/*.pbxproj') }}-${{ github.sha }}
                     restore-keys: |
                         ${{ runner.os }}-xcode-26.0-release-derived-${{ hashFiles('**/*.pbxproj') }}-
                         ${{ runner.os }}-xcode-26.0-release-derived-

               - name: Build Release
                 run: |
                     xcodebuild -quiet build -scheme iMCP \
                       -configuration Release -destination "platform=macOS" $SIGNING_OVERRIDES

       # The scripts are the release, install and ship paths; a syntax error in
       # one should fail here rather than halfway through a publish. Linux
       # runners ship shellcheck, python3 and node, and start in seconds.
       script-lint:
           name: Lint scripts
           runs-on: ubuntu-latest
           timeout-minutes: 5
           steps:
               - name: Checkout code
                 uses: actions/checkout@<CHECKOUT_SHA> # vX.Y.Z
                 with:
                     persist-credentials: false

               - name: Shell
                 run: |
                     shellcheck --version
                     shellcheck Scripts/*.sh

               - name: Python
                 run: python3 -m py_compile Scripts/*.py

               - name: Node
                 run: |
                     for script in Scripts/*.mjs; do
                         node --check "$script"
                     done
   ```

   Notes that are load-bearing:
   - The Release DerivedData cache key contains `-release-derived-`, which is
     not a prefix match for the Debug job's `-derived-` restore keys, and the
     reverse also holds. The two jobs must not restore each other's products.
   - `node --check` takes one file; the loop is required.
   - If, at execution time, `Scripts/` contains no `*.py` or no `*.mjs` file
     (check with `ls Scripts/*.py Scripts/*.mjs`), delete the step for the
     missing extension instead of leaving a glob that matches nothing.
   - Do not add `--severity`, `--exclude`, `continue-on-error` or `|| true`.

**Verify** (all must hold):

```bash
ruby -ryaml -e 'y = YAML.load_file(".github/workflows/ci.yml"); puts y["jobs"].keys.join(","); puts y["env"].keys.join(","); puts y["jobs"]["build"]["env"].keys.join(",")'
grep -cE 'uses: actions/(checkout|cache)@[0-9a-f]{40} # v[0-9]' .github/workflows/ci.yml
grep -cE 'uses: .*@v[0-9]' .github/workflows/ci.yml
grep -c 'persist-credentials: false' .github/workflows/ci.yml
grep -c 'SIGNING_OVERRIDES:' .github/workflows/ci.yml
grep -c -- '-configuration Release' .github/workflows/ci.yml
grep -n 'name: Build on macOS' .github/workflows/ci.yml
git diff --stat
```

→ in order: `build,release-build,script-lint`; `SIGNING_OVERRIDES`;
`DEVELOPER_DIR`; `7`; `0`; `3`; `1`; `1`; one line, text identical to today's
line 20; diff lists only `.github/workflows/ci.yml` (plus Step 2's script
commit already made). Commit (commit 2).

### Step 6 (operator-gated): prove it on a real CI run

A workflow change is verified only by the workflow running. Do this step only
when the operator explicitly tells you to open the PR. Until then, stop after
Step 5 and report "ready for PR".

```bash
git push -u origin advisor/052-ci-hardening
gh pr create --repo cyberpapiii/iMCP --base main --head advisor/052-ci-hardening \
  --title "ci: pin actions, lint scripts, and build Release" --fill
gh pr checks <PR_URL> --repo cyberpapiii/iMCP --watch
```

**Verify**: a green run shows exactly three checks, all `pass`:

- `Build on macOS 26 with Xcode 26.0`
- `Release build on macOS 26 with Xcode 26.0`
- `Lint scripts`

Then read the timings (read-only):

```bash
gh run list --repo cyberpapiii/iMCP --branch advisor/052-ci-hardening --limit 1 --json databaseId --jq '.[0].databaseId'
gh run view <RUN_ID> --repo cyberpapiii/iMCP --json jobs --jq '.jobs[] | "\(.name)  \(.conclusion)  \(.startedAt) -> \(.completedAt)"'
```

Report the duration of each job. The first Release run is a cold build; that
number is the worst case. Do NOT merge the PR; the operator merges.

Permitted fixes on a red run, one attempt each, then STOP:

- `Lint scripts` fails on a shellcheck finding you did not see locally (the
  runner's shellcheck version is printed at the top of the step and may be
  older than yours): handle it by the Step 2 rules and push.
- `Release build` fails with a signing error naming `Developer ID
  Application` or team `TTY35UM57S` (the SDK-conditional settings at
  `project.pbxproj:1071,1075` were not overridden): append these two quoted
  arguments to the `Build Release` command only, and push:
  `"CODE_SIGN_IDENTITY[sdk=macosx*]=-" "DEVELOPMENT_TEAM[sdk=macosx*]="`
- `Release build` hits the 20-minute timeout on the cold run: raise that job's
  `timeout-minutes` to 30, push once, and report both durations.

Any Swift compile error in `Release build` is a real finding: STOP and report
the error lines. Do not fix Swift in this plan.

## Test plan

No Swift tests are added: this plan changes no Swift. The workflow is its own
test, and Step 6 is where it runs.

- Positive: the three checks listed in Step 6 pass on the PR.
- Local equivalents that must pass before the PR: the three lint commands
  (Step 2), the YAML parse and grep counts (Step 5), and the local Release
  compile (Step 4).
- Negative check, local only, to prove the lint gate bites (do not commit):
  `printf 'if then\n' > "${TMPDIR%/}/bad.sh" && shellcheck "${TMPDIR%/}/bad.sh"; echo "exit $?"; rm "${TMPDIR%/}/bad.sh"`
  → non-zero exit.
- The existing gates are unchanged and must still hold:
  `swift format lint --strict --recursive .` → exit 0.

## Done criteria

ALL must hold:

- [ ] `grep -cE 'uses: .*@v[0-9]' .github/workflows/ci.yml` prints `0`
- [ ] `grep -cE 'uses: actions/(checkout|cache)@[0-9a-f]{40} # v[0-9]' .github/workflows/ci.yml` prints `7`
- [ ] `grep -c 'persist-credentials: false' .github/workflows/ci.yml` prints `3`
- [ ] `ruby -ryaml -e 'puts YAML.load_file(".github/workflows/ci.yml")["jobs"].keys.join(",")'` prints `build,release-build,script-lint`
- [ ] `shellcheck Scripts/*.sh` exits 0
- [ ] `PYTHONPYCACHEPREFIX="$(mktemp -d)" python3 -m py_compile Scripts/*.py` exits 0
- [ ] every `Scripts/*.mjs` passes `node --check`
- [ ] `git status --short` shows nothing outside `.github/workflows/ci.yml`, `Scripts/*.sh` and `plans/README.md`; no `Scripts/__pycache__`
- [ ] The `build` job's `name:` line is unchanged
- [ ] If the operator authorised Step 6: the PR on `cyberpapiii/iMCP` shows the three checks passing and the job durations are in the report
- [ ] `plans/README.md` status row updated (`DONE` only after a green run; otherwise `IN PROGRESS — awaiting operator PR`)

## STOP conditions

Stop and report back (do not improvise) if:

- Plans 050 or 051 are not `DONE`, or any of the four orphan scripts named in
  Step 1 still exists. Linting scripts that are about to be deleted or
  rewritten wastes the fix.
- `.github/workflows/ci.yml` does not match the "Current state" excerpt (for
  example the action tags are no longer `@v6` / `@v5`, or there is already
  more than one job).
- A SHA lookup fails, returns something that is not 40 hex characters, or the
  `gh api` and `git ls-remote` answers disagree. Never substitute a SHA from
  memory, from a web page, or from another repository's workflow.
- shellcheck reports more than five findings, or a finding whose fix would
  change what a script does. That work belongs to plan 050.
- A `.py` or `.mjs` file under `Scripts/` fails to parse.
- The Release build fails to compile, locally (Step 4) or in CI (Step 6).
- You would need to edit Swift, `project.pbxproj`, an entitlements file,
  `Scripts/ship.sh` logic, or the `build` job's name to get green.
- Any command would push to, or open a PR against, `upstream` / `mattt/iMCP`.
- A permitted Step 6 fix has been tried once and the run is still red.

## Maintenance notes

- Pinned SHAs do not update themselves. To bump an action, repeat Step 3 for
  the new tag and change the SHA and the `# vX.Y.Z` comment together, in all
  places (`grep -n 'uses:' .github/workflows/ci.yml`). Adding Dependabot for
  `github-actions` was deliberately left out to keep this change small; it is
  the natural follow-up if manual bumps become a chore.
- The Xcode version now appears twice: the `build` job's matrix and the
  hardcoded `26.0` / `macos-26` in `release-build`. Change both together.
- `SIGNING_OVERRIDES` is now workflow-level. Any future macOS job gets it for
  free; a job that must sign for real has to override it.
- The Release job compiles with `App/App.CI.entitlements`, so it proves
  Release compiles and links, not that the shipped entitlements or the
  WeatherKit capability are valid. `Scripts/release.sh` remains the only check
  of real signing.
- `ship.sh` waits for all checks, so the Release job's duration is added to
  every ship if it is the slowest job. If warm runs exceed the test job by
  more than a couple of minutes, the cheapest lever is `ONLY_ACTIVE_ARCH=YES`
  on the `Build Release` command (gives up the Intel compile); decide that
  with the Step 6 timings in hand.
- If branch protection on `cyberpapiii/iMCP` uses required status checks, the
  two new check names must be added there by a human for them to be required
  rather than merely watched by `ship.sh`.
- Reviewer focus: that each SHA really is the commit behind the tag in its
  comment (re-run the two `gh api` commands), that the Debug and Release
  DerivedData cache keys cannot restore each other, and that nothing in the
  `build` job changed beyond the three `uses:` lines and the moved `env`.
- New scripts under `Scripts/` are linted automatically by the globs. A new
  script language (e.g. `.rb`) needs its own step.
- Nothing here changes the app; do not run `Scripts/install-local.sh` for this
  plan unless the operator asks.
