# Plan 050: Make the release, ship, install, doctor, and benchmark scripts fail safe

> **Executor instructions**: Follow this plan unit by unit. Run every
> verification command and confirm the expected result before moving on. If
> anything in the "STOP conditions" section occurs, stop and report — do not
> improvise. When done, update the status row for this plan in
> `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **You may NOT execute any file under `Scripts/`** in this plan, not even with
> `help`, `--help`, or a dry-run flag. These scripts publish releases, push to
> GitHub, kill the installed app, and replace `/Applications/iMCP.app`. You edit
> their text and check it with `bash -n`, `shellcheck`, and `node --check` only.
> Everything that needs a real run is listed under "HUMAN STEPS" at the end.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- Scripts/release.sh Scripts/ship.sh Scripts/install-local.sh Scripts/doctor.sh Scripts/verify-app-signing.sh Scripts/test.sh Scripts/bench-full-stack-performance.mjs AlwaysOnHelper/main.swift`
> Plan 037 is expected to have changed `Scripts/ship.sh` and `Scripts/test.sh`
> (see "Dependency on plan 037" below). Any other changed file: compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (the scripts cannot be run by the executor; correctness rests on
  static checks plus the human steps at the end)
- **Depends on**: plans/037-isolate-tests-from-real-state.md
- **Category**: bug / security / dx
- **Planned at**: commit `8165d29`, 2026-10-12

## Why this matters

This repository is a fork. `origin` is `cyberpapiii/iMCP` (writable); `upstream`
is `mattt/iMCP` and must never receive a push, a PR, or a release. Today the
guard in `Scripts/release.sh` that is supposed to enforce that prints an error
and then publishes anyway, a bare `Scripts/release.sh` with no arguments bumps,
commits, tags, pushes and publishes, and `Scripts/ship.sh` commits every
untracked file in the checkout behind a credential blocklist that misses
`.env.local`, SSH keys and `.netrc`. `Scripts/install-local.sh` kills the
running app before it knows the build will succeed, and keeps every backup it
has ever made (54 zips, 513 MB on the owner's Mac on 2026-10-12).
`Scripts/doctor.sh` and the benchmark report green results they did not
measure. The always-on watchdog stops watching forever after one failed
relaunch.

After this plan: every release and ship command resolves its GitHub repository
once and refuses upstream; a failed publish or a failed CI run can be resumed by
re-running the same command; nothing destructive happens by default; and the
diagnostics only report what they checked. The change nets roughly 20 fewer
lines, mostly by deleting the legacy `all` release path and the blocklist.

## Dependency on plan 037

Plan 037 replaces the block in `Scripts/ship.sh` that stops the app and runs the
tests itself (lines 152–251 at `8165d29`: `build-for-testing`, the `pgrep`/
`pkill` block, `restore_app`, `run_bounded_app_tests`, the `case` on its exit
status) with a call to `Scripts/test.sh`, and fixes trap ordering and suite
selection in `Scripts/test.sh`.

Check before starting:

```console
$ grep -c 'run_bounded_app_tests' Scripts/ship.sh
0
```

If the count is not `0`, plan 037 has not landed: STOP.

Because of that replacement, **line numbers in `Scripts/ship.sh` after line 151
and all line numbers in `Scripts/test.sh` are not reliable**. This plan quotes
the code to find; locate it by content. Line numbers for every other file are
exact at `8165d29`.

## Current state

All excerpts are from commit `8165d29`.

### `Scripts/release.sh` (570 lines) — release automation

Called by `Scripts/ship.sh` twice: `release.sh bump` before the commit and
`release.sh publish` after the merge. Nothing else in the repository calls it.

**The upstream guard does not stop anything** (`:432-451`):

```bash
release_repo_args() {
  local repo="${RELEASE_REPO:-}"
  if [[ -z "${repo}" ]]; then
    local origin
    origin="$(git remote get-url origin 2>/dev/null || true)"
    if [[ "${origin}" == *mattt/iMCP* ]]; then
      echo "error: origin is upstream mattt/iMCP; set RELEASE_REPO to your fork" >&2
      exit 1
    fi
  else
    printf '%s\n' -R "${repo}"
  fi
}

create_release() {
  require_version
  echo "Creating GitHub release ${VERSION}"
  # shellcheck disable=SC2046
  gh $(release_repo_args) release create "${VERSION}" --generate-notes
}
```

`exit 1` inside `$(...)` ends only the subshell. Bash does not abort a command
because a substitution in its arguments failed, so `gh release create` runs with
no `-R`. The same pattern is at `:467` and `:469`. Confirmed in bash 3.2 (the
only bash on macOS): `f() { exit 1; }; echo before $(f) after` prints
`before after` and exits 0. With no `-R`, `gh` picks the repository itself, and
in a checkout that has an `upstream` remote that choice is not guaranteed to be
`origin`.

**Tags are pushed to an unnamed remote, all of them** (`:429`):

```bash
  git push --tags
```

**`publish` does not check where HEAD is** (`:488-492`). The comment promises
"reviewed main"; the code only requires a clean tree:

```bash
publish() {
  # Version bump must already be merged. This keeps public releases attached to
  # reviewed main instead of a local release-only commit.
  require_clean_tree
  build_check
```

**The default command publishes** (`:515`): `COMMAND="${1:-all}"`. `all`
(`:472-486`) bumps, archives, notarizes, commits, tags, pushes tags, creates the
release and uploads. `all` and `commit_and_tag` (`:373-395`, also the `commit`
command at `:547-549`) are the pre-`ship.sh` flow; `ship.sh --release` replaced
them with `bump` + PR + `publish`, and `git grep -n 'release.sh'` shows no other
caller.

**A failed publish cannot be resumed.** `tag_current_commit` (`:397-413`) runs
after archive, export, notarize, staple and package, and refuses an existing
tag even when it points at HEAD:

```bash
  if git rev-parse --verify "refs/tags/${VERSION}" >/dev/null 2>&1; then
    echo "Tag already exists: ${VERSION}" >&2
    exit 1
  fi
```

`gh release create` (`:450`) likewise fails if the release already exists.

**`check` can verify a stale export** (`:72-76`). `build_check` (`:272-277`)
builds, then calls `resolve_app_bundle`, which prefers whatever is lying in
`dist/export/` over the product it just built, and overrides an explicit
`APP_BUNDLE` too:

```bash
resolve_app_bundle() {
  resolve_exported_app || true
  if [[ -d "${APP_BUNDLE}" ]]; then
    return 0
  fi
```

**Dead output** — `:363` writes `dist/iMCP-<version>.zip.sha256`, which is never
uploaded and names a different file from the uploaded asset (`dist/iMCP.zip`,
`:461`). `:469` opens a browser (`gh ... release view --web`) after a successful
upload, which fails on a headless run and turns a finished release into a
non-zero exit.

### `Scripts/ship.sh` (336 lines at `8165d29`) — commit, PR, CI, merge, install

**A flag given last exits silently** (`:37-48`, three copies):

```bash
    -m|--message)
      COMMIT_MESSAGE="${2:-}"
      shift 2
      ;;
```

`shift 2` with one argument left fails under `set -e`: exit 1, no message.

**The remote check lets upstream through** (`:96-100`):

```bash
origin_url="$(git remote get-url "${REMOTE}")"
if [[ "${origin_url}" != *"github.com"* ]]; then
  echo "error: ${REMOTE} is not a GitHub remote: ${origin_url}" >&2
  exit 1
fi
```

`REMOTE` comes from `IMCP_SHIP_REMOTE` (`:6`). `IMCP_SHIP_REMOTE=upstream`
passes this check, then pushes a branch to and opens a PR on `mattt/iMCP`.
`origin_url` is used once more, in the line that begins
`repo="$(gh repo view "${origin_url}"` (`:256`).

**A run that stopped at CI cannot be resumed** (`:109-119`, and after the test
block the lines `git commit -m "${COMMIT_MESSAGE}"`, `git push --set-upstream`,
`pr_url="$(gh pr create ...`):

```bash
has_shipping_changes() {
  git status --porcelain --untracked-files=all | awk '
    substr($0, 4) !~ /^\.hermes\// { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

if ! has_shipping_changes; then
  echo "error: no changes to ship (.hermes is preserved and excluded)" >&2
  exit 1
fi
```

After a CI failure the commit is already pushed and the PR is open. Re-running
with a clean tree stops at "no changes to ship". Re-running with a fix commits
and pushes, then `gh pr create` fails because the PR exists.
`has_shipping_changes` is used a second time, in the block that begins
`if [[ -z "${main_root}" ]]; then`.

**Every untracked file is committed** (`:134-149`):

```bash
swift format -i -r .
git add -A -- . ':(exclude).hermes'

if git diff --cached --quiet; then
  echo "error: no staged changes after formatting" >&2
  exit 1
fi

while IFS= read -r staged_path; do
  case "${staged_path}" in
    *.p8|*.p12|*.mobileprovision|*.provisionprofile|*.key|*.pem|.env|*/.env)
      echo "error: refusing to commit possible credential: ${staged_path}" >&2
      exit 1
      ;;
  esac
done < <(git diff --cached --name-only --diff-filter=ACMR)
```

The blocklist misses `.env.local`, `id_rsa`, `.netrc`, JSON service-account
keys and `*.keychain-db`. A blocklist of extensions cannot be completed; not
adding untracked files can. `.hermes/` is an untracked, un-ignored directory
(`git ls-files .hermes` is empty, `.gitignore` has no `.hermes` line), which is
why it is excluded by pathspec.

**Cleanup fails after a successful ship** (near the end of the file):

```bash
if [[ "${ORIGINAL_ROOT}" != "${main_root}" ]]; then
  cd "${main_root}"
  git worktree remove "${ORIGINAL_ROOT}"
  git worktree prune
fi
```

`git worktree remove` refuses a worktree holding untracked files (`.hermes`)
and refuses the primary checkout. Under `set -e` the script exits non-zero
after the PR is merged and the app is installed.

### `Scripts/install-local.sh` (223 lines) — build, sign, install to `/Applications`

**A personal signing identity is hardcoded** at `:9`
(`DEFAULT_SIGN_IDENTITY="..."`; read the line in the file — do not copy its
value into a commit message, a PR, a comment, or this plan). It is used only at
`:45`:

```bash
if [[ -z "${SIGN_IDENTITY}" && -d "${INSTALL_APP}" ]]; then
  installed_authority="$(codesign -dv --verbose=4 "${INSTALL_APP}" 2>&1 | awk -F= '/^Authority=/ {print $2; exit}' || true)"
  case "${installed_authority}" in
    "Apple Development:"*|"Plug Local Signing")
      if security find-identity -v -p codesigning | grep -qF "\"${installed_authority}\""; then
        SIGN_IDENTITY="${installed_authority}"
      fi
      ;;
  esac
fi
SIGN_IDENTITY="${SIGN_IDENTITY:-${DEFAULT_SIGN_IDENTITY}}"
```

So the literal only matters when no usable app is installed. Two things already
protect the owner's permissions and stay untouched: the block above reuses the
installed app's identity, and `:100-114` refuses to install when the designated
requirement would change. `App/Shared/ListenerEndpointFile.swift:244` mentions
"`Scripts/install-local.sh` default identity" in a comment above the
`Plug Local Signing` requirement; the Swift code reads the team from its own
signature (`:238-240`) and does not depend on the literal. Leave the Swift file
alone.

**The app is killed 18 lines before the build starts** (`:47-50`; `xcodebuild`
is at `:66`):

```bash
if [[ "${COMMAND}" != "install" ]]; then
  pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
  pkill -x imcp-server >/dev/null 2>&1 || true
fi
```

A compile or signing error leaves iMCP down. `open_app` (`:191-201`) already
stops the app at the right moment, after the new bundle is in place:

```bash
open_app() {
  # The always-on watchdog can relaunch the app while the build is running, so
  # whatever is running now may still be the binary that was just replaced.
  # Stop it and wait for it to go before opening the new one.
  pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "${APP_NAME}" >/dev/null 2>&1 || break
    sleep 0.5
  done
  /usr/bin/open "${INSTALL_APP}"
}
```

The `debug` command (`:207-209`) does not call `open_app`; it relies on the
early kill.

**`rm -rf` on an environment-supplied path** (`:7`, `:129`):
`INSTALL_APP="${IMCP_INSTALL_APP:-/Applications/iMCP.app}"` then, guarded only
by `[[ -d "${INSTALL_APP}" ]]`, `rm -rf "${INSTALL_APP}"`.
`IMCP_INSTALL_APP=/Applications` would delete `/Applications`.

**Backups are never pruned** (`:116-128`). Each install writes
`${BACKUP_DIR}/iMCP-<UTC timestamp>.zip`, e.g. `iMCP-20261012T091500Z.zip`. The
timestamp format sorts chronologically as text.

**Installing removes the test host** (`:152-169`): `cleanup_build_apps` deletes
every `~/Library/Developer/Xcode/DerivedData/iMCP-*/Build/Products/*/iMCP.app`.
That bundle hosts the app test suite, so `Scripts/test.sh --no-build` fails
after any install. `AGENTS.md` requires the cleanup (duplicate bundles confuse
Launch Services), so the fix is one line of help text, not a weaker cleanup.

### `Scripts/doctor.sh` (102 lines) — read-only install report

`:12` ignores the variable `install-local.sh` installs to:

```bash
APP="/Applications/iMCP.app"
```

`:66-72`, three defects in one check:

```bash
recent_denials="$(log show --predicate 'process == "iMCP"' --last 1h --style compact 2>/dev/null \
  | grep -c 34018)"
if [[ "${recent_denials}" == "0" ]]; then
  pass "no errSecMissingEntitlement in the last hour of app logs"
else
  fail "${recent_denials} keychain entitlement denials in the last hour"
fi
```

1. `process == "iMCP"` also matches the XCTest host (an iMCP.app built in
   DerivedData), so a test run produces a FAIL about the installed app.
2. `grep -c 34018` matches those digits anywhere: a pid, a thread id, a
   timestamp fraction.
3. If `log show` fails, the pipeline still yields `0` and the check passes.

### `Scripts/verify-app-signing.sh` (70 lines) — signature and entitlement asserts

The same two parses are written out eight times across three files:

| Parse | Copies |
| --- | --- |
| `codesign -dv --verbose=4 X 2>&1 \| awk -F= '/^Authority=/ {print $2; exit}'` | `install-local.sh:36`, `:85`, `:121`; `doctor.sh:25` |
| `codesign -d -r- X 2>&1 \| sed -n 's/^designated => //p'` | `install-local.sh:101`, `:102`; `doctor.sh:34`; `verify-app-signing.sh:60` |

### `Scripts/bench-full-stack-performance.mjs` (365 lines) — installed-app benchmark

Run through `Scripts/measure-full-stack-performance.sh`, which passes
`--app "${IMCP_INSTALL_APP:-/Applications/iMCP.app}"`.

`:44-51` finds, and `:219-222` terminates, every process named `iMCP`, which
includes an Xcode-run build and the XCTest host:

```js
function appPids() {
    try {
        const output = execFileSync("/usr/bin/pgrep", ["-x", "iMCP"], { encoding: "utf8" }).trim();
```

`:132` writes to `child.stdin` with no `error` listener. An `EPIPE` from an
exited `imcp-server` is an unhandled stream error that kills the process before
`restore()` (`:276-285`) puts the app back.

`:200-214` `preflight` calls `readySession`, whose loop (`:180-195`) starts a
new `imcp-server` every 3 s until the 20 s deadline. With an unapproved client
key each one raises an approval prompt in the app: about six prompts for one
failed preflight.

`:304-313` measures dispatch latency but never looks at the response, so a
request that failed for another reason, or one that succeeded and beeped, is
timed as a dispatch. `App/Services/Utilities.swift:29-31` throws
`ToolInputError("Invalid sound")` for the benchmark's sound name, which reaches
the client as a tool result with `isError: true`.

`:346` and `:348` are gates that cannot fail:

```js
            connect_success_rate: 1,
            tool_count_stable: uniqueToolCounts.length === 1 && uniqueToolCounts[0] > 0,
            app_relaunch_success_rate: startup.length / args.startupRuns,
```

`benchmarkStartup` throws before returning a short array, so the third is
always `1`. No file outside `Scripts/` reads either field.

### `AlwaysOnHelper/main.swift` (71 lines) — the `iMCPAlwaysOn` watchdog

`:46-52`:

```swift
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
            if let error {
                logger.error("Failed to relaunch iMCP: \(error.localizedDescription, privacy: .public)")
            } else if let application {
                self.watch(application)
            }
        }
```

After a failed relaunch nothing is watching and nothing retries; `run()` sits
in `RunLoop.main.run()` forever. launchd would retry for us — the agent plist
`AlwaysOnHelper/co.dododo.iMCP.always-on.plist` has `KeepAlive` true and
`ThrottleInterval` 1 — but only if the helper exits.

### Conventions that apply

- All shell scripts start with `#!/usr/bin/env bash` and must run on macOS's
  bash 3.2: no `${var,,}`, no `mapfile`, no associative arrays, and an empty
  array must be expanded as `${arr[@]+"${arr[@]}"}` under `set -u`.
- Required flag values use `${2:?message}` — see `Scripts/test.sh`, the `--only`
  arm: `only_specs+=("${2:?--only needs a test specifier}")`. Match it.
- `shellcheck` reports nothing for any of the six scripts today. It must report
  nothing when you finish; do not add `# shellcheck disable` lines.
- Comments explain why, in plain sentences, and are kept short. Do not delete or
  shorten existing comments unless the code they describe is deleted.
- Use `/usr/bin/log`, never bare `log` (`install-local.sh:212` already does).
- JavaScript in `Scripts/*.mjs` uses 4-space indentation and double quotes.

## Commands you will need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| Shell syntax | `bash -n Scripts/<file>.sh` | exit 0, no output |
| Shell lint | `shellcheck Scripts/release.sh Scripts/ship.sh Scripts/install-local.sh Scripts/doctor.sh Scripts/verify-app-signing.sh Scripts/test.sh` | exit 0, no output |
| JS syntax | `node --check Scripts/bench-full-stack-performance.mjs` | exit 0, no output |
| Build (unit 7 only) | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| Swift format (unit 7 only) | `swift format -i AlwaysOnHelper/main.swift` then `swift format lint --strict --recursive .` | exit 0 |

`shellcheck` is installed at `/opt/homebrew/bin/shellcheck`. If
`command -v shellcheck` prints nothing, STOP.

Do not run `Scripts/test.sh`, `xcodebuild test`, or any other script in this
plan. Never `launchctl bootout` the always-on agent.

## Scope

**In scope** (the only files you should modify):

- `Scripts/release.sh`
- `Scripts/ship.sh`
- `Scripts/install-local.sh`
- `Scripts/doctor.sh`
- `Scripts/verify-app-signing.sh`
- `Scripts/test.sh` — one line of `--help` text only
- `Scripts/bench-full-stack-performance.mjs`
- `AlwaysOnHelper/main.swift`

**Out of scope** (do NOT touch, even though they look related):

- `AGENTS.md`, `README.md` — plan 053 owns the docs. The wording they need is
  listed under "Maintenance notes".
- `Scripts/bench-mcp-client.mjs`, `Scripts/measure-mcp-client.sh`,
  `Scripts/measure-runtime-efficiency.py`, `Scripts/find-my-people-key.py` —
  plan 051 deletes them.
- `Scripts/find-my-people-bootstrap.sh`, `Scripts/find_my_people_key.py`,
  `Scripts/observe-find-my-people.sh`,
  `Scripts/verify-find-my-people-security.sh` — plan 046.
- `.github/workflows/ci.yml` — plan 052 (which adds `shellcheck` to CI and
  depends on this plan leaving the scripts clean).
- The entitlement assertions in `Scripts/verify-app-signing.sh:49-58` — plan
  051 changes them.
- `App/Shared/ListenerEndpointFile.swift` and its comment at `:244`.
- `AlwaysOnHelper/co.dododo.iMCP.always-on.plist`.
- Any `--dry-run` flag for `ship.sh`. It does not fall out of this change and
  is deliberately not added.

## Git workflow

- Start from an up-to-date `main` that contains plan 037.
- Branch: `advisor/050-script-safety`.
- One commit per unit, conventional-commit style, matching the log, e.g.
  `fix: bring Settings forward from the menu; stay quiet on relaunch`.
  Suggested subjects are given in each unit.
- Do NOT push or open a PR unless the operator instructed it. `origin`
  (`cyberpapiii/iMCP`) is the only writable remote; never push or open a PR
  against `upstream` (`mattt/iMCP`).
- Do not use `Scripts/ship.sh` to land this plan: it is one of the files being
  changed and you may not execute it.

## Steps

### Unit 1: `Scripts/release.sh`

**1a. Resolve the repository once.** Below the `NOTARY_ZIP=` line (`:24`) add:

```bash
RELEASE_REMOTE="${RELEASE_REMOTE:-origin}"
RELEASE_REPO=""
```

Replace the whole `release_repo_args` function (`:432-444`) with:

```bash
# Sets RELEASE_REPO to the owner/name behind RELEASE_REMOTE. Call it as a plain
# command, never inside $(...): `exit` in a command substitution ends only the
# subshell, which is how an upstream origin once printed an error and published
# anyway.
resolve_release_repo() {
  local url
  url="$(git remote get-url "${RELEASE_REMOTE}")"
  if [[ "${url}" != *github.com[:/]* ]]; then
    echo "error: ${RELEASE_REMOTE} is not a GitHub remote: ${url}" >&2
    exit 1
  fi
  RELEASE_REPO="${url#*github.com[:/]}"
  RELEASE_REPO="${RELEASE_REPO%.git}"
  if [[ "$(printf '%s' "${RELEASE_REPO}" | tr '[:upper:]' '[:lower:]')" == "mattt/imcp" ]]; then
    echo "error: ${RELEASE_REMOTE} is upstream mattt/iMCP, which never receives tags or releases; set RELEASE_REMOTE to your fork's remote" >&2
    exit 1
  fi
}
```

`RELEASE_REPO` is no longer read from the environment: the repository is always
the one behind the remote the tag is pushed to, so the two cannot disagree.

Check the expansion in a throwaway shell (this does not run the script):

```console
$ bash -c 'for url in git@github.com:cyberpapiii/iMCP.git https://github.com/cyberpapiii/iMCP.git; do r="${url#*github.com[:/]}"; echo "${r%.git}"; done'
cyberpapiii/iMCP
cyberpapiii/iMCP
```

**1b. Use it everywhere `gh` or `git push` runs.**

- `push_tags`: call `resolve_release_repo` right after `require_version`.
  Change the prompt to `"Push tag ${VERSION} to ${RELEASE_REPO}? [y/N] "`.
  Replace `git push --tags` with:

  ```bash
  git push "${RELEASE_REMOTE}" "refs/tags/${VERSION}"
  ```

- `create_release` becomes:

  ```bash
  create_release() {
    require_version
    resolve_release_repo
    if gh release view "${VERSION}" -R "${RELEASE_REPO}" >/dev/null 2>&1; then
      echo "GitHub release ${VERSION} already exists; resuming"
      return 0
    fi
    echo "Creating GitHub release ${VERSION} on ${RELEASE_REPO}"
    gh release create "${VERSION}" -R "${RELEASE_REPO}" --verify-tag --generate-notes
  }
  ```

  `--verify-tag` makes `gh` fail instead of creating the tag itself when the
  tag is not on the remote.

- `upload_asset`: call `resolve_release_repo` after `require_version`; replace
  the last five lines of the function (two `shellcheck disable` comments, the
  `release upload` line, the `release view --web` line) with:

  ```bash
  # --clobber so a resumed publish can replace a partial upload.
  gh release upload "${VERSION}" "${upload_path}" -R "${RELEASE_REPO}" --clobber
  ```

- `preflight`: replace `release_repo_args >/dev/null` with:

  ```bash
  resolve_release_repo
  echo "RELEASE_REPO=${RELEASE_REPO}"
  ```

- Add a function and a command that `ship.sh` will use in unit 2:

  ```bash
  print_release_repo() {
    resolve_release_repo
    printf '%s\n' "${RELEASE_REPO}"
  }
  ```

  and in the `case` at the bottom, before `preflight)`:

  ```bash
    repo)
      print_release_repo
      ;;
  ```

**1c. Delete the legacy direct-release path.** Delete the `all()` function
(`:472-486`), the `commit_and_tag()` function (`:373-395`), and the `all)` and
`commit)` arms of the `case` (`:517-519`, `:547-549`). Change `:515` to:

```bash
COMMAND="${1:-help}"
```

**1d. Make `publish` check its commit and its tag before building.** Add above
`tag_current_commit`:

```bash
# A tag already at HEAD is an earlier publish of this same commit, to resume.
require_tag_free_or_at_head() {
  local tagged
  tagged="$(git rev-parse --verify --quiet "refs/tags/${VERSION}^{commit}" || true)"
  if [[ -n "${tagged}" && "${tagged}" != "$(git rev-parse HEAD)" ]]; then
    echo "error: tag ${VERSION} already exists on another commit (${tagged})" >&2
    exit 1
  fi
}
```

In `tag_current_commit`, replace the four-line `if git rev-parse --verify ...
Tag already exists ... fi` block (`:407-410`) with:

```bash
  require_tag_free_or_at_head
  if git rev-parse --verify --quiet "refs/tags/${VERSION}" >/dev/null; then
    echo "Tag ${VERSION} already points at HEAD; resuming"
    return 0
  fi
```

Change the start of `publish` (keep its existing comment) to:

```bash
  require_version
  require_clean_tree
  resolve_release_repo
  git fetch "${RELEASE_REMOTE}" main
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse FETCH_HEAD)" ]]; then
    echo "error: HEAD is not ${RELEASE_REMOTE}/main; publish only the merged commit" >&2
    exit 1
  fi
  require_tag_free_or_at_head
  build_check
```

The rest of `publish` is unchanged.

**1e. Stop `check` verifying a stale export.** Replace `resolve_app_bundle` and
`require_app_bundle` (`:72-100`) with:

```bash
resolve_built_app() {
  local settings built_products_dir full_product_name
  settings="$(xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "${DESTINATION}" -showBuildSettings)"
  built_products_dir="$(printf '%s\n' "${settings}" | awk -F ' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')"
  full_product_name="$(printf '%s\n' "${settings}" | awk -F ' = ' '/FULL_PRODUCT_NAME/ {print $2; exit}')"
  APP_BUNDLE="${built_products_dir}/${full_product_name}"
}

# An explicit or already-resolved APP_BUNDLE wins; a step run on its own
# (notarize, staple, package) falls back to the exported app.
require_app_bundle() {
  if [[ ! -d "${APP_BUNDLE}" ]] && ! resolve_exported_app; then
    echo "Missing app bundle: ${APP_BUNDLE} (run export, or set APP_BUNDLE)" >&2
    exit 1
  fi
}
```

In `build_check` replace `resolve_app_bundle` with `resolve_built_app`. In
`export_app` replace `resolve_app_bundle` with:

```bash
  if ! resolve_exported_app; then
    echo "error: export produced no app in ${EXPORT_DIR}" >&2
    exit 1
  fi
```

`resolve_exported_app` is defined further down the file (`:208`); bash resolves
function names at call time, so the order is fine.

**1f. Delete the unused checksum.** Delete `:363`
(`shasum -a 256 "${release_zip_path}" > "${release_zip_path}.sha256"`).

**1g. Update `print_usage`.** Delete the `all` and `commit` lines. Add
`repo        Print the GitHub owner/name that tags and releases go to`. Change
the `publish` line to say it requires HEAD to be the remote's `main` and can be
re-run after a failure. Change the `push-tags` line to "Push the release tag".
Replace the `RELEASE_REPO` environment line with
`RELEASE_REMOTE    Git remote for tags and releases (default: origin; upstream mattt/iMCP is refused)`.
Change the `preflight` line to say "release-remote" instead of `RELEASE_REPO`.

**Verify**:

```console
$ bash -n Scripts/release.sh && shellcheck Scripts/release.sh; echo "rc=$?"
rc=0
$ grep -c 'release_repo_args\|SC2046\|commit_and_tag\|resolve_app_bundle\|sha256\|--web\|push --tags' Scripts/release.sh
0
$ grep -c -- '-R "${RELEASE_REPO}"' Scripts/release.sh
3
$ grep -n 'COMMAND="${1:-' Scripts/release.sh
<one line>:COMMAND="${1:-help}"
$ grep -c '^all()\|^  all)\|^  commit)' Scripts/release.sh
0
$ grep -c '\$(resolve_release_repo\|\$(print_release_repo' Scripts/release.sh
0
```

Commit: `fix(release): refuse upstream, publish only merged main, resume a failed publish`

### Unit 2: `Scripts/ship.sh`

**2a. Required flag values.** In the three arms `-m|--message`, `-t|--title`,
`--release`, replace `"${2:-}"` with `"${2:?--message needs a value}"`,
`"${2:?--title needs a value}"`, `"${2:?--release needs a version}"`.

**2b. Share the remote check with `release.sh`.** Replace the five lines
`origin_url="$(git remote get-url "${REMOTE}")"` … `fi` (`:96-100`) with:

```bash
# release.sh owns the rule: a GitHub remote, and never upstream mattt/iMCP.
repo="$(RELEASE_REMOTE="${REMOTE}" "${ROOT_DIR}/Scripts/release.sh" repo)"
```

Delete the later line that begins `repo="$(gh repo view "${origin_url}"`. In
the `--release` block near the end, change the publish call to
`VERSION="${RELEASE_VERSION}" RELEASE_REMOTE="${REMOTE}" Scripts/release.sh publish`.

**2c. Refuse untracked files; allow a resume.** Delete the
`has_shipping_changes` function and the `if ! has_shipping_changes; then … fi`
gate (`:109-119`). In their place, keeping the existing
`git fetch "${REMOTE}" "${BASE_BRANCH}"` line where shown, write:

```bash
untracked="$(git -C "${ROOT_DIR}" ls-files --others --exclude-standard -- . ':(exclude).hermes')"
if [[ -n "${untracked}" ]]; then
  echo "error: untracked files. git add the ones that belong in this change; remove or ignore the rest:" >&2
  printf '%s\n' "${untracked}" | sed 's/^/  /' >&2
  exit 1
fi

git fetch "${REMOTE}" "${BASE_BRANCH}"

# Commits on this branch that the base lacks are a run to resume: an earlier
# attempt committed and pushed, then stopped at CI.
if git diff --quiet HEAD -- \
  && [[ "$(git rev-list --count "${REMOTE}/${BASE_BRANCH}..HEAD")" == "0" ]]; then
  echo "error: nothing to ship" >&2
  exit 1
fi
```

There must be exactly one `git fetch "${REMOTE}" "${BASE_BRANCH}"` line in the
file afterwards.

**2d. Stage tracked files only; delete the blocklist.** Replace
`git add -A -- . ':(exclude).hermes'` with `git add -u`. Delete the
`if git diff --cached --quiet; then … no staged changes after formatting … fi`
block and the whole `while IFS= read -r staged_path; do … done < <(git diff
--cached --name-only --diff-filter=ACMR)` loop (`:137-149`). New files the
operator staged with `git add` are already in the index and are committed;
nothing else can be.

**2e. Commit only when there is something to commit; reuse an open PR.**
Replace the line `git commit -m "${COMMIT_MESSAGE}"` with:

```bash
if git diff --cached --quiet; then
  echo "No new changes to commit; resuming with the commits already on ${current_branch}"
else
  git commit -m "${COMMIT_MESSAGE}"
fi
```

Replace the line that begins `pr_url="$(gh pr create` with:

```bash
pr_url="$(gh pr list --repo "${repo}" --head "${current_branch}" --state open --json url --jq '.[0].url // empty')"
if [[ -z "${pr_url}" ]]; then
  pr_url="$(gh pr create --repo "${repo}" --base "${BASE_BRANCH}" --head "${current_branch}" --title "${PR_TITLE}" --fill)"
fi
```

**2f. Wait for checks on the commit that was just pushed.** A resumed PR
already has checks, from the previous head. In the `for _ in {1..150}` loop,
add `head_sha="$(git rev-parse HEAD)"` on the line before the loop, and replace
the `check_count=` line and the `if` under it with:

```bash
  check_count="$(gh pr view "${pr_url}" --repo "${repo}" --json headRefOid,statusCheckRollup \
    --jq "select(.headRefOid == \"${head_sha}\") | .statusCheckRollup | length")"
  if [[ "${check_count:-0}" -gt 0 ]]; then
```

**2g. The second use of `has_shipping_changes`.** In the block that begins
`if [[ -z "${main_root}" ]]; then`, replace `&& ! has_shipping_changes; then`
with `&& git diff --quiet HEAD --; then`.

**2h. Non-fatal worktree cleanup.** Replace
`git worktree remove "${ORIGINAL_ROOT}"` with:

```bash
  # Refused for the primary checkout and for a worktree with untracked files
  # (.hermes). The ship already succeeded; say so and carry on.
  git worktree remove "${ORIGINAL_ROOT}" \
    || echo "warning: kept ${ORIGINAL_ROOT}; remove it by hand if it is no longer needed" >&2
```

**2i. Update `usage`.** Under the options list add two lines:

```text
New files must be staged with git add first; untracked files stop the run.
Re-run the same command to resume after a CI failure (re-run the failed check
on GitHub first if there is no new commit).
```

**Verify**:

```console
$ bash -n Scripts/ship.sh && shellcheck Scripts/ship.sh; echo "rc=$?"
rc=0
$ grep -c 'has_shipping_changes\|origin_url\|add -A\|refusing to commit\|"\${2:-}"' Scripts/ship.sh
0
$ grep -c 'git fetch "${REMOTE}" "${BASE_BRANCH}"' Scripts/ship.sh
1
$ grep -c 'Scripts/release.sh" repo\|gh pr list\|git add -u\|worktree remove "${ORIGINAL_ROOT}" \\' Scripts/ship.sh
4
```

Commit: `fix(ship): resume after CI failure, stage tracked files only, refuse upstream`

### Unit 3: `Scripts/install-local.sh` and one line in `Scripts/test.sh`

**3a. Prove the identity fallback selects the same identity (run BEFORE
editing).** This prints one word and never the identity:

```console
$ old="$(git show 8165d29:Scripts/install-local.sh | sed -n 's/^DEFAULT_SIGN_IDENTITY="\(.*\)"$/\1/p')"; new="$(security find-identity -v -p codesigning | awk -F'"' '/"Apple Development:/ {print $2; exit}')"; [[ -n "${old}" && "${old}" == "${new}" ]] && echo SAME || echo DIFFERENT
SAME
```

`DIFFERENT` is a STOP condition (see below). Do not paste either value
anywhere.

**3b. Replace the literal.** Delete `:9` (`DEFAULT_SIGN_IDENTITY=...`). Replace
`:45` (`SIGN_IDENTITY="${SIGN_IDENTITY:-${DEFAULT_SIGN_IDENTITY}}"`) with:

```bash
# Nothing installed to match: use this Mac's first Apple Development identity.
if [[ -z "${SIGN_IDENTITY}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/"Apple Development:/ {print $2; exit}')"
fi
```

Change the existence check (`:52`) so an empty identity cannot pass
`grep -qF ""`:

```bash
if [[ -z "${SIGN_IDENTITY}" ]] || ! security find-identity -v -p codesigning | grep -qF "${SIGN_IDENTITY}"; then
  echo "error: code-signing identity not found: ${SIGN_IDENTITY:-none; set IMCP_SIGN_IDENTITY}" >&2
  exit 1
fi
```

**3c. Do not kill the app before the build.** Delete `:47-50` (the
`if [[ "${COMMAND}" != "install" ]]; then pkill … fi` block). Split `open_app`
so `debug` can still stop the old process:

```bash
stop_app() {
  # The always-on watchdog can relaunch the app while the build is running, so
  # whatever is running now may still be the binary that was just replaced.
  # Stop it and wait for it to go before opening the new one.
  pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "${APP_NAME}" >/dev/null 2>&1 || break
    sleep 0.5
  done
}

open_app() {
  stop_app
  /usr/bin/open "${INSTALL_APP}"
}
```

and make the `debug)` arm:

```bash
  debug)
    stop_app
    lldb -- "${INSTALL_APP}/Contents/MacOS/${APP_NAME}"
    ;;
```

**3d. Guard the path that gets `rm -rf`.** Directly below the `BUNDLE_ID=` line
(`:13`) add:

```bash
# This path is removed with rm -rf before the new bundle moves in.
if [[ "${INSTALL_APP}" != /*/iMCP.app ]]; then
  echo "error: IMCP_INSTALL_APP must be an absolute path ending in /iMCP.app: ${INSTALL_APP}" >&2
  exit 2
fi
```

**3e. Keep the five newest backups.** Directly after the line
`echo "Installed verified local build: ${INSTALL_APP}"` (`:141`) add:

```bash
# Each backup is a whole app bundle. The timestamped names sort oldest first.
backups=("${BACKUP_DIR}"/iMCP-*.zip)
if ((${#backups[@]} > 5)); then
  rm -f "${backups[@]:0:${#backups[@]}-5}"
fi
```

With no backups the glob stays literal, the count is 1, and nothing is removed.

**3f. `Scripts/test.sh` help.** In the `usage` heredoc, change the `--no-build`
line to:

```text
      --no-build         Skip build-for-testing and run the existing products
                         (Scripts/install-local.sh removes them; rebuild after an install)
```

Change nothing else in `test.sh`.

**Verify**:

```console
$ bash -n Scripts/install-local.sh && bash -n Scripts/test.sh && shellcheck Scripts/install-local.sh Scripts/test.sh; echo "rc=$?"
rc=0
$ grep -c 'DEFAULT_SIGN_IDENTITY\|pkill -x imcp-server' Scripts/install-local.sh
0
$ grep -c 'pkill -x "${APP_NAME}"' Scripts/install-local.sh
1
$ grep -n 'xcodebuild \\' Scripts/install-local.sh | head -1    # note the line number N
$ awk 'NR < N && /pkill/' N=<that line number> Scripts/install-local.sh | wc -l
0
$ git diff 8165d29 -- Scripts/install-local.sh | grep -c '^+.*Apple Development: [A-Z][a-z]'
0
```

The last check proves no personal identity string was added.

Commit: `fix(install): keep the app up until the build succeeds; prune backups; no hardcoded identity`

### Unit 4: `Scripts/doctor.sh`

Change `:12` to:

```bash
APP="${IMCP_INSTALL_APP:-/Applications/iMCP.app}"
```

Replace `:66-72` (the `recent_denials=` assignment and its `if`/`else`/`fi`)
with:

```bash
# Only the installed app: the XCTest host is also a process named iMCP.
if denial_log="$(/usr/bin/log show --last 1h --style compact \
  --predicate "processImagePath BEGINSWITH \"${APP}/\" AND eventMessage CONTAINS \"-34018\"" 2>/dev/null)"; then
  recent_denials="$(printf '%s\n' "${denial_log}" | grep -c -- '-34018')"
  if [[ "${recent_denials}" == "0" ]]; then
    pass "no errSecMissingEntitlement in the last hour of app logs"
  else
    fail "${recent_denials} keychain entitlement denials in the last hour"
  fi
else
  warn "could not read the unified log, so keychain denials were not checked"
fi
```

`log show` prints a header line even with no matches, which is why the count is
of `-34018`, not of lines. `doctor.sh` runs without `set -e`, so `grep -c`
exiting 1 on zero matches is harmless.

**Verify**:

```console
$ bash -n Scripts/doctor.sh && shellcheck Scripts/doctor.sh; echo "rc=$?"
rc=0
$ grep -c 'process == "iMCP"\|grep -c 34018' Scripts/doctor.sh
0
$ grep -c 'IMCP_INSTALL_APP\|processImagePath BEGINSWITH\|/usr/bin/log show' Scripts/doctor.sh
3
```

Commit: `fix(doctor): count keychain denials from the installed app only`

### Unit 5: one definition of the two `codesign` parses

In `Scripts/verify-app-signing.sh`, between `set -euo pipefail` (`:2`) and
`APP_BUNDLE="${1:-}"` (`:4`), add:

```bash
# The only place these two codesign outputs are parsed. Both print nothing,
# and still exit 0, for an unsigned or unreadable bundle.
print_authority() {
  codesign -dv --verbose=4 "$1" 2>&1 | awk -F= '/^Authority=/ {print $2; exit}' || true
}
print_requirement() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p' || true
}
case "${1:-}" in
  --print-authority) print_authority "${2:?app bundle path}"; exit 0 ;;
  --print-requirement) print_requirement "${2:?app bundle path}"; exit 0 ;;
esac
```

Change `:60` to `DESIGNATED_REQUIREMENT="$(print_requirement "${APP_BUNDLE}")"`.

Replace the seven other copies, keeping each variable name:

| File and variable | New right-hand side |
| --- | --- |
| `install-local.sh` `installed_authority` | `"$("${ROOT_DIR}/Scripts/verify-app-signing.sh" --print-authority "${INSTALL_APP}")"` |
| `install-local.sh` `staged_authority` | `… --print-authority "${STAGED_APP}")"` |
| `install-local.sh` `existing_authority` | `… --print-authority "${INSTALL_APP}")"` |
| `install-local.sh` `installed_requirement` | `… --print-requirement "${INSTALL_APP}")"` |
| `install-local.sh` `staged_requirement` | `… --print-requirement "${STAGED_APP}")"` |
| `doctor.sh` `authority` | `"$("$(dirname "${BASH_SOURCE[0]}")/verify-app-signing.sh" --print-authority "${APP}")"` |
| `doctor.sh` `installed_requirement` | `"$("$(dirname "${BASH_SOURCE[0]}")/verify-app-signing.sh" --print-requirement "${APP}")"` |

Do not change the lines around them: the empty-value checks that follow each
assignment (`install-local.sh:103-106`, `doctor.sh:26`, `:35`) are what handle
an unsigned bundle.

**Verify**:

```console
$ for f in verify-app-signing install-local doctor; do bash -n "Scripts/${f}.sh" || echo "BAD ${f}"; done; shellcheck Scripts/verify-app-signing.sh Scripts/install-local.sh Scripts/doctor.sh; echo "rc=$?"
rc=0
$ grep -c "Authority=\|designated => " Scripts/install-local.sh Scripts/doctor.sh Scripts/release.sh Scripts/ship.sh
Scripts/install-local.sh:0
Scripts/doctor.sh:0
Scripts/release.sh:0
Scripts/ship.sh:0
$ grep -c "Authority=\|designated => " Scripts/verify-app-signing.sh
2
$ grep -c -- '--print-authority\|--print-requirement' Scripts/install-local.sh Scripts/doctor.sh
Scripts/install-local.sh:5
Scripts/doctor.sh:2
```

Commit: `refactor(scripts): parse codesign authority and requirement in one place`

### Unit 6: `Scripts/bench-full-stack-performance.mjs`

**6a. Match the app by executable path.** Change the `node:fs` import to
`import { existsSync, realpathSync } from "node:fs";`. Replace `appPids`
(`:44-51`) with:

```js
// Set in main() from --app. Matching the executable path leaves an Xcode-run
// build and the XCTest host, which are also processes named iMCP, alone.
let appExecutable = null;

function appPids() {
    try {
        return execFileSync("/bin/ps", ["-axo", "pid=,comm="], { encoding: "utf8" })
            .split("\n")
            .map((line) => line.trim().match(/^(\d+)\s+(.*)$/))
            .filter((match) => match && match[2] === appExecutable)
            .map((match) => Number(match[1]));
    } catch {
        return [];
    }
}
```

In `main`, directly after the `existsSync` check (`:272`), add:

```js
    appExecutable = `${realpathSync(args.app)}/Contents/MacOS/iMCP`;
```

No call site of `appPids()` changes.

**6b. Handle a closed pipe.** In `MCPSession.start`, after
`this.child.on("error", …)` (`:90`), add:

```js
        this.child.stdin.on("error", (error) => this.failAll(error));
```

**6c. One preflight attempt.** Replace the body of `preflight` (`:200-214`),
keeping the comment above it but changing its last sentence to "Try once, up
front, and say how to fix it.":

```js
async function preflight(args) {
    const session = new MCPSession(args.binary, args.timeoutMs);
    try {
        await session.start();
        await session.request("tools/list", {});
    } catch (error) {
        if (/initialize timed out/.test(error.message)) {
            throw new Error(
                "initialize timed out: this client key is not approved. Approve it in iMCP, " +
                "or set IMCP_KEY_FILE to an approved client key (Debug builds only)"
            );
        }
        throw error;
    } finally {
        session.close();
    }
}
```

`readySession` stays; `benchmarkStartup` still needs its retry loop.

**6d. Assert the dispatch response.** In the `dispatchWork` callback
(`:304-313`), capture and check the response:

```js
            const { message } = await session.request("tools/call", {
                name: "utilities_beep",
                arguments: { sound: "__imcp_benchmark_invalid__" },
            });
            if (!message.error && message.result?.isError !== true) {
                throw new Error("utilities_beep accepted the invalid sound; dispatch was not measured");
            }
            return elapsedMs(started);
```

Leave the `cpuWork` callback (`:316-321`) as it is.

**6e. Delete the constant gates.** Delete the `connect_success_rate: 1,` line
(`:346`) and the `app_relaunch_success_rate: startup.length / args.startupRuns,`
line (`:348`). Keep `tool_count_stable`.

**6f. Header comment.** Replace `:2-4` with:

```js
// Full-stack benchmark for installed iMCP. stdout is one JSON object only.
// It terminates and relaunches the app at --app, which ends every connected
// client's session. Requests use tools/list or an invalid utilities_beep
// payload, so no user data is returned or persisted and no beep is produced.
```

**Verify**:

```console
$ node --check Scripts/bench-full-stack-performance.mjs; echo "rc=$?"
rc=0
$ grep -c 'pgrep\|connect_success_rate\|app_relaunch_success_rate' Scripts/bench-full-stack-performance.mjs
0
$ grep -c 'stdin.on("error"\|match\[2\] === appExecutable\|dispatch was not measured' Scripts/bench-full-stack-performance.mjs
3
```

Commit: `fix(bench): target only the installed app; assert the measured response`

### Unit 7: `AlwaysOnHelper/main.swift`

Replace the completion handler body (`:47-51`) with:

```swift
            if let error {
                logger.error("Failed to relaunch iMCP: \(error.localizedDescription, privacy: .public)")
                // Nothing is being watched now. launchd restarts the helper
                // (KeepAlive), and the fresh start retries the launch.
                exit(1)
            } else if let application {
                self.watch(application)
            }
```

`exit` comes from `Darwin`, already imported at `:2`. Change nothing else in
the file.

**Verify**:

```console
$ swift format -i AlwaysOnHelper/main.swift && swift format lint --strict --recursive . ; echo "rc=$?"
rc=0
$ xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build; echo "rc=$?"
rc=0
$ grep -c 'exit(1)' AlwaysOnHelper/main.swift
1
$ git diff --stat HEAD -- AlwaysOnHelper/
 AlwaysOnHelper/main.swift | 3 +++
```

Do not test this by stopping, unloading, or `bootout`-ing the always-on agent.

Commit: `fix(always-on): exit when a relaunch fails so launchd retries`

## Test plan

There is no test harness for the shell scripts, the benchmark, or the
`iMCPAlwaysOn` target (`iMCPTests/AlwaysOnServiceTests.swift` covers the app's
registration of the agent, not `AlwaysOnHelper/main.swift`, which is top-level
script code). Do not build one for this plan.

- Every unit's gate is static: `bash -n`, `shellcheck` with no output,
  `node --check`, and the `grep` counts in its Verify block.
- Unit 7 is additionally gated by a Debug build and the format lint.
- No new test file and no `project.pbxproj` edit.
- Behaviour is confirmed by the human steps below. That is the accepted cost of
  the rule that agents do not execute these scripts.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `shellcheck Scripts/release.sh Scripts/ship.sh Scripts/install-local.sh Scripts/doctor.sh Scripts/verify-app-signing.sh Scripts/test.sh` exits 0 with no output
- [ ] `grep -rn 'shellcheck disable' Scripts/release.sh Scripts/ship.sh Scripts/install-local.sh Scripts/doctor.sh Scripts/verify-app-signing.sh` returns no matches
- [ ] `node --check Scripts/bench-full-stack-performance.mjs` exits 0
- [ ] `grep -c 'release_repo_args\|commit_and_tag\|push --tags' Scripts/release.sh` prints `0`
- [ ] `grep -c 'COMMAND="${1:-help}"' Scripts/release.sh` prints `1`
- [ ] `grep -c 'add -A\|has_shipping_changes\|refusing to commit' Scripts/ship.sh` prints `0`
- [ ] `grep -c 'DEFAULT_SIGN_IDENTITY' Scripts/install-local.sh` prints `0`
- [ ] `git diff 8165d29 -- Scripts/ AlwaysOnHelper/ | grep -c '^+.*Apple Development: [A-Z][a-z]'` prints `0`
- [ ] `grep -c 'process == "iMCP"' Scripts/doctor.sh` prints `0`
- [ ] `grep -c 'pgrep' Scripts/bench-full-stack-performance.mjs` prints `0`
- [ ] `grep -c 'exit(1)' AlwaysOnHelper/main.swift` prints `1`
- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `git diff --stat 8165d29..HEAD --shortstat -- Scripts/release.sh` shows more deletions than insertions
- [ ] `git status --short` lists no file outside the in-scope list
- [ ] `plans/README.md` status row updated
- [ ] The "HUMAN STEPS" list below was handed to the operator in the final report

## STOP conditions

Stop and report back (do not improvise) if:

- `grep -c 'run_bounded_app_tests' Scripts/ship.sh` is not `0` (plan 037 has
  not landed), or `ship.sh` after plan 037 no longer contains one of the lines
  this plan tells you to find by content (`git add -A -- . ':(exclude).hermes'`,
  `git commit -m "${COMMIT_MESSAGE}"`, `pr_url="$(gh pr create`,
  `git worktree remove "${ORIGINAL_ROOT}"`).
- Step 3a prints `DIFFERENT`. The stable signing identity is what keeps the
  owner's macOS privacy grants and Keychain access; the fallback must select
  the same identity the literal named. Leave `:9` and `:45` as they are, finish
  the rest of unit 3, and report it.
- You find yourself about to run anything under `Scripts/`, `xcodebuild test`,
  `gh release`, `gh pr`, `git push`, `git tag`, `pkill`, `launchctl`, or
  `codesign --sign`. None of those is needed to execute this plan.
- `shellcheck` reports a finding you can only silence with a `disable` comment.
- A unit's Verify block fails twice after a reasonable fix attempt.
- A fix appears to require touching an out-of-scope file (for example the
  docs, the agent plist, or `ListenerEndpointFile.swift`).
- Any excerpt in "Current state" for a file other than `ship.sh`/`test.sh` does
  not match the live code.

## HUMAN STEPS (hand these to the operator; do not perform them)

Release publishing, pushing, and installing are human-initiated. After the
branch is reviewed, the operator runs, in this order:

1. `Scripts/release.sh` — prints the help text and exits 0 (it used to start a
   release).
2. `Scripts/release.sh repo` — prints `cyberpapiii/iMCP`.
   `RELEASE_REMOTE=upstream Scripts/release.sh repo` — prints the upstream
   error and exits 1.
3. `Scripts/install-local.sh run`, then `Scripts/doctor.sh` — "All checks
   passed", no new permission or Keychain prompt, and at most five zips in
   `~/Library/Application Support/iMCP/Local Install Backups`. The first run
   deletes the older backups (49 of 54 on 2026-10-12); copy any you want first.
4. `Scripts/measure-full-stack-performance.sh` with an approved `IMCP_KEY_FILE`
   — one JSON object without `connect_success_rate` or
   `app_relaunch_success_rate`.
5. The next real `Scripts/ship.sh -m "..."` and the next
   `Scripts/ship.sh --release <version>` are the end-to-end checks of units 1
   and 2. Nothing short of a real ship or release exercises them.

## Maintenance notes

- **Docs wording for plan 053** (this plan does not edit docs):
  - `AGENTS.md:44` says the benchmark "uses side-effect-free MCP requests".
    Accurate wording: it terminates and relaunches the installed app, which
    ends every connected client's session; the MCP requests themselves return
    and persist no user data.
  - `AGENTS.md:87-91` and `README.md:377-381` say `ship.sh` "commits and pushes
    all changes except `.hermes`" and that "possible credential files are
    rejected". After this plan: it commits tracked changes and files already
    staged with `git add`, stops when untracked files exist, and can be re-run
    to resume after a CI failure.
  - `README.md:354-356` says the installer "defaults to" a named person's Apple
    Development identity. After this plan: it defaults to the first Apple
    Development identity in the keychain.
  - `AGENTS.md:75` can mention that `Scripts/release.sh` with no arguments
    prints help and that `RELEASE_REMOTE` replaces `RELEASE_REPO`.
- The identity string removed from `install-local.sh:9` remains in git history.
  Removing it there means rewriting published history; that is the owner's
  call and not part of this plan.
- `release.sh publish` hardcodes `main`; `ship.sh` has `IMCP_SHIP_BASE_BRANCH`.
  A ship with a non-default base plus `--release` now stops at the publish
  check. If that combination is ever wanted, pass the branch through the same
  way `RELEASE_REMOTE` is passed.
- A resumed `ship.sh --release` runs `release.sh bump` again, which raises the
  build number a second time and produces one more commit. Harmless; fixing it
  means teaching `bump` to detect an already-applied version.
- `install-local.sh run`/`verify`/`logs`/`telemetry`/`debug` no longer
  `pkill imcp-server`. Running proxies end when their app connection drops at
  relaunch, and the default `install` command never killed them.
- If relaunching keeps failing, the watchdog now exits and launchd restarts it
  about once a second (`ThrottleInterval` 1), logging one error each time,
  instead of idling silently. If that proves noisy, raise `ThrottleInterval`
  in the plist rather than removing the exit.
- Plan 051 edits the entitlement assertions in `verify-app-signing.sh`; unit 5
  adds lines at the top of that file and changes one line near the bottom.
  Expect a trivial merge if both are open at once.
- Plan 052 adds `shellcheck` to CI and depends on these six scripts staying
  clean.
- Reviewer focus: `resolve_release_repo` must never appear inside `$(...)`;
  the order of checks at the top of `publish`; the untracked-file gate and the
  nothing-to-ship gate in `ship.sh`; and step 3a's result.
- Do not run `Scripts/install-local.sh` as part of executing this plan. It is
  the operator's step 3 above.
