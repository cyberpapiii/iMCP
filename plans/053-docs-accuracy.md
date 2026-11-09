# Plan 053: Make AGENTS.md, README.md and the old design docs say what the code does

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. Do **not** edit `plans/README.md`; the advisor
> maintains the index. Report your result to the operator instead.
>
> **Run this plan LAST.** It documents what the code does, so every other plan
> in this batch (037 to 052, 054) should have landed or been rejected first.
> Start from an up-to-date `main`.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- AGENTS.md README.md docs/plans/`
> Then, because this plan is meant to run after other plans changed the code:
> `git diff --stat 8165d29..HEAD -- App/Services CLI App/Shared Scripts iMCP.xcodeproj/project.pbxproj`
> Drift in the second command is **expected**, not a STOP. It means the facts in
> "Current state" may be out of date: every step below tells you which command
> to run to re-derive the fact from the live tree, and the live tree wins.
> Drift in the first command (the docs themselves) means compare the excerpts
> below with the live files; if a quoted line is gone or reworded, apply the
> step's intent to the new wording, and STOP only if you cannot find the claim
> the step is correcting.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW — documentation only; no Swift, script, or project-file change
- **Depends on**: none for content. Sequencing: run after 037 to 052 and 054 so
  the docs describe what actually landed.
- **Category**: docs
- **Planned at**: commit `8165d29`, 2026-10-12

## Why this matters

`AGENTS.md` is the file every agent reads before touching this repo, and it
currently points them at the wrong file for the stdio proxy, tells them a test
command that fails on this machine is a normal option, and calls a benchmark
that kills the running app "side-effect-free". `README.md` tells users the app
"collects nothing and stores nothing" two screens above a section explaining
that it stores their Apple ID password in the Keychain and 90 days of location
history on disk. Three design docs under `docs/plans/` still state decisions
(the password is never persisted; an opt-in checkbox; two tool renames) that
were reversed, so an agent reading them will "fix" the code back to the old
design. Each of these is a wrong statement, not a missing one, and each is
cheap to correct.

## Current state

All facts below were verified at `8165d29` by reading the files. Paths are
relative to the repo root.

### A. `AGENTS.md` (105 lines)

Commands block, test section:

```markdown
<!-- AGENTS.md:19-27 -->
# Run the existing CLI tests
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"

# Run app-side unit tests
xcodebuild test -scheme iMCP -destination "platform=macOS"

# Or run both suites with the installed app stopped, which is what the app
# suite needs in order to launch its test bundle at all
Scripts/test.sh
```

Why it is wrong: the always-on watchdog (`iMCPAlwaysOn`) relaunches
`/Applications/iMCP.app`, and a running installed app makes the app suite fail
to launch its test bundle ("LaunchServices launcher has returned an error").
`Scripts/test.sh` exists to handle that (`Scripts/test.sh:4-11`). Its options
(`Scripts/test.sh:13-24`):

```
      --app-only         Run only the app suite
      --cli-only         Run only the CLI suite
      --only SPEC        Pass -only-testing:SPEC (repeatable, implies --app-only)
      --no-build         Skip build-for-testing and run the existing products
```

`SPEC` is an `xcodebuild -only-testing:` value, for example
`iMCPTests/VisitInferenceTests`.

Benchmark paragraph:

```markdown
<!-- AGENTS.md:42-47 -->
The full-stack benchmark measures `/Applications/iMCP.app`, not an Xcode build
product. Its `imcp-server` sessions need an approved client key; set
`IMCP_KEY_FILE` to one, or the run stops at the first `initialize`. It relaunches the app, uses side-effect-free MCP requests, restores the
initial running state, and emits one JSON object. Compare code candidates against
```

What the benchmark does (`Scripts/bench-full-stack-performance.mjs`): its MCP
requests are `tools/list` and an invalid `utilities_beep` payload, so no user
data is returned (`:3-4`). But `benchmarkStartup` sends `SIGTERM` to every
running `iMCP` process once per startup run (`:218-223`, default 3 runs, set by
`BENCH_STARTUP_RUNS` in `Scripts/measure-full-stack-performance.sh:28`) and
reopens the app. Every MCP client connected at that moment loses its session.
The requests are harmless; the run is not.

Key paths:

```markdown
<!-- AGENTS.md:63 -->
- `App/Services/` - one file per MCP service.
<!-- AGENTS.md:70-74 -->
- `App/Shared/` - pairing and auth code compiled into **both** the app and the
  CLI targets, mainly `AuthPreamble.swift` and `ListenerEndpointFile.swift`.
- `CLI/` - the CLI target. `main.swift` is the stdio proxy; alongside it sit
  `BonjourEndpointSelection.swift`, `CLIBootstrap.swift`, `ClientKeyStore.swift`,
  and `MessageFrameScanner.swift`.
```

What is true:

- `App/Services/` has one file per service **plus** `App/Services/Location/`
  with 12 supporting files (`FindMyClient`, `FindMyPeopleBootstrap`,
  `FindMyPeopleReadiness`, `ICloudAuthClient`, `ICloudCredentialStorage`,
  `ICloudHTTP`, `LocalStorageKeyStorage`, `LocalStoragePeopleProvider`,
  `LocationHistoryStore`, `LocationSampler`, `VenueLookup`, `VisitInference`),
  and two shared store helpers (`BookmarkedSQLiteStore.swift`,
  `RemoteNotificationsStore.swift`).
- `App/Shared/` has 7 files. Only 4 are compiled into the CLI:
  `AuthPreamble.swift`, `ListenerEndpointFile.swift`, `OneShotSignal.swift`,
  `ResumeGate.swift` (they are the only `App/Shared/` paths with explicit
  entries in `iMCP.xcodeproj/project.pbxproj`, lines 155 and 180-182). The
  other 3 (`ConnectionApprovalPairing.swift`, `PairingCodeIssuer.swift`,
  `SecretFileStore.swift`) are app-only. `App/` is a synchronized group, so a
  new file there is in the app automatically; the CLI needs hand-made pbxproj
  entries.
- `CLI/` has 7 Swift files: `main.swift` (40 lines, argument handling and
  startup), `StdioProxy.swift` (`actor StdioProxy` at `CLI/StdioProxy.swift:74`,
  the stdio-to-socket proxy), `MCPService.swift` (endpoint discovery and
  connection lifecycle), and the four files already listed.
- Not mentioned anywhere in `AGENTS.md`: `AlwaysOnHelper/` (`main.swift` plus
  `co.dododo.iMCP.always-on.plist`; the `iMCPAlwaysOn` watchdog target that
  relaunches the installed app), `Packages/SRP/` (local Swift package with
  `SRPClient.swift` and `SRPMath.swift`, the SRP math for iCloud sign-in),
  `iMCPTests/` (app tests), `CLITests/` (CLI tests, scheme `imcp-serverTests`).
- Test files are not in a synchronized group: a new test file needs four
  hand-made `project.pbxproj` entries (PBXBuildFile, PBXFileReference, group
  child, Sources phase). This is undocumented and is the most common way an
  agent's new test silently never runs.

### B. `README.md` (636 lines)

| Line | Text today | What is true |
|------|------------|--------------|
| 12 | `The app itself collects nothing and stores nothing.` | See "Stored locally" below. |
| 122 | `(requires macOS 15.0 or later).` | The app, CLI and watchdog targets deploy to macOS 15.1 (`MACOSX_DEPLOYMENT_TARGET = 15.1`). Line 122 sits under a note saying the download is the *upstream* build, whose requirement this repo does not control. |
| 155-158 | `iMCP **does not** collect or store any of your data.` | Same as line 12. |
| 312 | ``See [`StdioProxy`](CLI/main.swift)`` | `StdioProxy` is in `CLI/StdioProxy.swift`. |
| 330-331 | `xcodebuild test -scheme imcp-serverTests ...` and `xcodebuild test -scheme iMCP ...` under "use the same commands CI uses" | Fails locally under the watchdog; `Scripts/test.sh` is the way. CI itself runs `build-for-testing` then `test-without-building` (`.github/workflows/ci.yml:72-83`), so the block is not even what CI runs. |
| 107 | Weather: `Current weather for any location, including temperature and wind speed.` | Four tools: `weather_current`, `weather_hourly`, `weather_daily`, `weather_minute`. The service is registered only when `WEATHERKIT_AVAILABLE` is set (`App/Controllers/ServiceRegistry.swift:276`), which only the app target's Release configuration does (`project.pbxproj:1045`). A Debug/source build has no Weather service. |
| 524 | ``the `fetchContacts` tool`` | No such tool. The tool is `contacts_search`. |
| 555, 578 | `> "Copy server command to clipboard"` | No such menu item. The menu item is `Connect a Client…` (`App/Views/ContentView.swift:140`); that window has a **Copy** button beside the server command (`App/Views/ConnectClientWindow.swift:133`). |

**Stored locally** (each verified in code):

- `~/Library/Application Support/iMCP/location-history.sqlite` — position
  samples (deleted after 90 days) and the places the user named
  (`App/Services/Location/LocationHistoryStore.swift:177-181`, tables `samples`
  and `places`). Only while Location is on.
- Data-protection Keychain, this device only — the iCloud sign-in: Apple ID
  password, session and trust tokens, cookies
  (`App/Services/Location/ICloudCredentialStorage.swift:24-54`, field
  `password` at `:54`). `README.md:428-432` already says this correctly.
- Keychain — paired-client public-key fingerprints (service
  `co.dododo.iMCP.paired-clients`, `App/Controllers/PairedClientStorage.swift:9`)
  and the CLI's P-256 signing key (`README.md:277`).
- `UserDefaults` — which services are on, and other settings.
- `~/Library/Application Support/iMCP/listener-endpoint.json` — the loopback
  port (`App/Shared/ListenerEndpointFile.swift:85`).

**Sent off the Mac by the app**: only requests to Apple. The only outbound
hosts in `App/` are `idmsa.apple.com`, `setup.icloud.com`, `www.icloud.com`
(iCloud sign-in and Find My), plus Apple frameworks that call Apple themselves
(MapKit for Maps, WeatherKit for Weather). There is no analytics or telemetry
endpoint. The MCP client the user connects receives tool results and may send
them anywhere.

**Capability table (`README.md:16-109`) versus registered tools.** Tool names
at `8165d29`, from
`grep -rhoE 'name: "[a-z]+_[a-z_]+"' App/Services/*.swift | sort -u`
(52 tools; `App/Services/Location/` is excluded because its `name:` matches are
OAuth form fields, not tools):

| Service | Tools | What the table row omits |
|---------|-------|--------------------------|
| Browser History | `browser_history_search` | nothing |
| Calendar | `calendars_list`, `events_fetch`, `events_create`, `events_delete` | listing calendars; **deleting events** |
| Call History | `calls_fetch` | nothing |
| Capture | `capture_take_picture`, `capture_record_audio`, `capture_take_screenshot` | nothing |
| Contacts | `contacts_me`, `contacts_search`, `contacts_create`, `contacts_update` | **creating and updating contacts** |
| Location | `location_now`, `location_timeline`, `location_visits`, `location_history`, `location_places`, `location_place_set`, `location_devices`, `location_people`, `location_friends`, `location_friend`, `location_ring` | recorded history and stays; **naming places**; **playing a sound on a device** is mentioned only as "sound playback" |
| Maps | `maps_search`, `maps_explore`, `maps_directions`, `maps_eta`, `maps_geocode`, `maps_reverse_geocode`, `maps_generate` | nothing |
| Messages | `messages_fetch` (arguments include `attachments`; results carry the conversation as `isPartOf`) | conversations and attachment listings |
| Notes | `notes_folders`, `notes_search`, `notes_fetch` | reading a note's full text |
| Notifications | `notifications_fetch` | nothing |
| Photos | `photos_search`, `photos_albums`, `photos_fetch_image` | listing albums; fetching an image |
| Reminders | `reminders_lists`, `reminders_fetch`, `reminders_create` | nothing |
| Screen Time | `screentime_usage`, `screentime_web_usage`, `screentime_device_activity` | nothing |
| Shortcuts | `shortcuts_list`, `shortcuts_run` | nothing |
| Utilities | `utilities_beep` | nothing |
| Weather | `weather_current`, `weather_hourly`, `weather_daily`, `weather_minute` | forecasts; Release-only |

Plan 054 adds write tools (update/delete verbs) and other plans may rename or
remove tools. That is why Step 5 re-runs the grep instead of trusting this
table.

### C. Decision drift in `docs/plans/`

These are dated design records. They stay as written; each gets a short dated
note at the top.

**Owner decision, 2026-10-12 (binding):** the Apple ID password is always
stored in the this-device-only data-protection Keychain item, together with the
session tokens. There is no "Keep me signed in" checkbox and no separate
password Keychain item.

1. `docs/plans/2026-08-23-1559-location-find-my-rebuild-plan.md`
   - `:16` — "The password is never persisted and never touched by an agent."
   - `:136` — "Never the password." and `:216` — "Any code path that persists
     the user's Apple ID password." (listed as forbidden)
   - `:43`, `:53`, `:152` — "all seven tools". Location declares 11
     (`grep -c 'name: "location_' App/Services/Location.swift` → `11`).
   - `:71-74` (D4) — renames `location_places` to `location_named_places` and
     `location_place_set` to `location_name_place`. Neither rename shipped:
     `git grep -n 'location_named_places\|location_name_place' -- App` returns
     nothing, and both original names are registered.
   - This file has no YAML frontmatter; line 1 is the `# ` title and line 3 is
     the `**Status**` line.
2. `docs/plans/2026-08-28-icloud-debug-session-durability-plan.md`
   - `:13` — "Keep passwords out of persistence."
   - `:26` (R4) — "Passwords are never persisted."
   - `:147` — "No password is persisted or printed."
   - YAML frontmatter on lines 1-7; the `# ` title is line 9.
3. `docs/plans/2026-09-02-icloud-session-survives-restart-plan.md`
   - `:35` (R5) — "Optional, user-decided: "Keep me signed in" ... Off by
     default".
   - `:56-63` (U3) — a separate Keychain item `co.dododo.iMCP.icloud-password`
     and a default-off checkbox on the sign-in sheet.
   - `:74` already records that U3 shipped with the password "in the same
     data-protection Keychain item as the tokens", but never says the checkbox
     and the separate item were dropped.
   - YAML frontmatter on lines 1-6; the `# ` title is line 8.

Code that proves the decision is what shipped: `git grep -n -i 'keep me signed
in\|icloud-password' -- App` returns nothing, and
`App/Services/Location/ICloudCredentialStorage.swift:54` is
`var password: String?` inside the single `ICloudCredentials` struct.

### Conventions

- Prose in both docs is wrapped at about 80 columns; keep that.
- `README.md` uses GitHub callouts (`> [!NOTE]`, `> [!IMPORTANT]`) and an HTML
  `<table>` for capabilities. Keep both forms.
- `AGENTS.md` Key paths bullets use ` - ` after the path (a plain hyphen).
  Match the existing bullets.
- `CLAUDE.md` is a 3-line pointer to `AGENTS.md`. Leave it alone.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| List registered tools | `grep -rhoE 'name: "[a-z]+_[a-z_]+"' App/Services/*.swift \| sort -u` | one line per tool |
| Shared files compiled into the CLI | `grep -o 'path = ../App/Shared/[A-Za-z]*.swift' iMCP.xcodeproj/project.pbxproj \| sort -u` | the files with explicit entries |
| Only docs changed | `git status --porcelain` | only the five in-scope files |
| Lint (confirms no Swift file was touched) | `swift format lint --strict --recursive .` | exit 0 |

No build and no tests are needed: nothing compiled changes. Do not run
`Scripts/test.sh`, `Scripts/install-local.sh`, or any other script for this
plan. Never run `xcodebuild test -scheme iMCP` directly (the watchdog relaunches
the installed app and breaks the test host), and never `launchctl bootout` the
always-on agent.

## Scope

**In scope** (the only files you should modify):

- `AGENTS.md`
- `README.md`
- `docs/plans/2026-08-23-1559-location-find-my-rebuild-plan.md`
- `docs/plans/2026-08-28-icloud-debug-session-durability-plan.md`
- `docs/plans/2026-09-02-icloud-session-survives-restart-plan.md`

**Out of scope** (do NOT touch, even though they look related):

- `plans/README.md` and every file under `plans/` — the advisor maintains them.
- Any `.swift` file. In particular the stale comment at
  `App/Services/Location/ICloudCredentialStorage.swift:5-9` ("The password is
  not here and is never written anywhere") belongs to plan 045.
- The About-box and Settings links in `App/Views/SettingsView.swift` (they
  point at upstream repositories) — plan 048.
- Anything under `Scripts/`. The benchmark's kill-by-name behaviour is plan
  050's; this plan only corrects the sentence that describes it.
- `.github/workflows/ci.yml` — plan 052.
- `docs/solutions/`, `docs/ideation/`, `docs/find-my-people-setup.md`, and the
  four other files in `docs/plans/`. They were not found to contradict the code.
- Rewriting the body of the three `docs/plans/` files. Add the note; change
  nothing below it.
- A per-tool reference list in the README. The owner wants verbs added to the
  existing rows, not a new table.
- The README download link, Homebrew cask line, and screenshots.

## Git workflow

- Start from an up-to-date `main`. Branch: `advisor/053-docs-accuracy`.
- One commit per file group is enough. Conventional commits, matching the repo
  (for example `fix: bring Settings forward from the menu; stay quiet on
  relaunch`). Suggested:
  - `docs(agents): correct key paths, test command, and benchmark side effects`
  - `docs(readme): say what is stored, list write tools, fix stale references`
  - `docs(plans): mark superseded password and rename decisions`
- Do NOT push or open a PR unless the operator says so. `origin`
  (`cyberpapiii/iMCP`) is the only writable remote; never push to or open a PR
  against `upstream` (`mattt/iMCP`).

## Steps

### Step 1: `AGENTS.md` — make `Scripts/test.sh` the only test command

In the Commands code block, replace lines 19-27 (the two `xcodebuild test`
commands and the "Or run both suites" comment) with:

```console
# Run both test suites. The script stops the installed app and its watchdog
# first and restores them afterwards; the app suite cannot launch otherwise.
Scripts/test.sh

# Narrow the run: --app-only, --cli-only, --no-build, or one app test class
Scripts/test.sh --only iMCPTests/VisitInferenceTests
```

Before writing it, read `Scripts/test.sh` lines 13-24 (read only; do not run
it) and confirm the four flags still exist with those meanings. If a flag was
renamed or removed, document the flags that exist.

Directly after the code block's closing fence, add one paragraph:

```markdown
Do not run the `iMCP` scheme's test action through `xcodebuild` yourself. The
always-on watchdog relaunches `/Applications/iMCP.app`, and a running installed
app stops the test bundle from launching. Never `launchctl bootout` the
watchdog to work around it; `Scripts/test.sh` pauses and resumes it.
```

**Verify**:
```console
grep -c '^xcodebuild test' AGENTS.md          # expect 0
grep -c 'Scripts/test.sh --only' AGENTS.md    # expect 1
```

### Step 2: `AGENTS.md` — state the benchmark's side effect

In the paragraph at `AGENTS.md:42-47`, replace the sentence

> It relaunches the app, uses side-effect-free MCP requests, restores the
> initial running state, and emits one JSON object.

with

> It terminates and relaunches the installed app several times, so every MCP
> client connected during a run loses its session; do not run it while a
> client is in use. Its own MCP requests return no user data. It restores the
> initial running state and emits one JSON object.

Re-wrap the paragraph to about 80 columns. Before writing, confirm with
`grep -n 'SIGTERM' Scripts/bench-full-stack-performance.mjs` that the script
still terminates the app. If it returns nothing, STOP (see STOP conditions).

**Verify**:
```console
grep -c 'side-effect-free' AGENTS.md      # expect 0
grep -c 'loses its session' AGENTS.md     # expect 1
```

### Step 3: `AGENTS.md` — correct Key paths

First re-derive the facts from the live tree:

```console
ls CLI/*.swift
ls App/Shared
ls App/Services/Location | wc -l
grep -o 'path = ../App/Shared/[A-Za-z]*.swift' iMCP.xcodeproj/project.pbxproj | sort -u
ls AlwaysOnHelper Packages/SRP/Sources iMCPTests CLITests >/dev/null && echo present
```

Use what these print. At `8165d29` they print the facts in "Current state"
section A. Then edit three existing bullets and add four, keeping the bullet
style:

1. Replace the `App/Services/` bullet (line 63) with:

   ```markdown
   - `App/Services/` - one file per MCP service. Location is the exception: its
     Find My client, iCloud sign-in, history store, sampler, and visit inference
     live in `App/Services/Location/`.
   ```

2. Replace the `App/Shared/` bullet (lines 70-71) with (list the files the
   pbxproj grep printed as the CLI ones, and the remaining `ls App/Shared`
   files as app-only):

   ```markdown
   - `App/Shared/` - small files used across targets. Four are compiled into
     **both** the app and the CLI: `AuthPreamble.swift`,
     `ListenerEndpointFile.swift`, `OneShotSignal.swift`, and `ResumeGate.swift`.
     The rest (`ConnectionApprovalPairing.swift`, `PairingCodeIssuer.swift`,
     `SecretFileStore.swift`) are app-only. A new file here joins the app
     automatically; the CLI needs explicit entries in
     `iMCP.xcodeproj/project.pbxproj`.
   ```

3. Replace the `CLI/` bullet (lines 72-74) with:

   ```markdown
   - `CLI/` - the `imcp-server` target. `main.swift` handles arguments and
     startup, `StdioProxy.swift` is the stdio proxy, and `MCPService.swift`
     finds and connects to the app. Alongside them sit
     `BonjourEndpointSelection.swift`, `CLIBootstrap.swift`,
     `ClientKeyStore.swift`, and `MessageFrameScanner.swift`.
   ```

4. Immediately after the `CLI/` bullet, add:

   ```markdown
   - `AlwaysOnHelper/` - the `iMCPAlwaysOn` watchdog target. It relaunches the
     installed app when it exits, which is why tests go through
     `Scripts/test.sh`.
   - `Packages/SRP/` - local Swift package with the SRP math for iCloud sign-in.
   - `iMCPTests/` (app, scheme `iMCP`) and `CLITests/` (CLI, scheme
     `imcp-serverTests`) - unit tests. Test files are not in a synchronized
     group: a new test file needs four hand-made entries in
     `iMCP.xcodeproj/project.pbxproj` (PBXBuildFile, PBXFileReference, group
     child, Sources phase), or it never runs. Prefer adding to an existing file.
   ```

If the `ls` output differs from the lists above (a file added, removed, or
moved by another plan), write what `ls` shows. Name only files that exist.

**Verify**:
```console
grep -c 'main.swift` is the stdio proxy' AGENTS.md        # expect 0
grep -c 'StdioProxy.swift' AGENTS.md                      # expect >= 1
grep -c 'MCPService.swift' AGENTS.md                      # expect >= 1
grep -c 'AlwaysOnHelper/' AGENTS.md                       # expect >= 1
grep -c 'Packages/SRP/' AGENTS.md                         # expect >= 1
grep -c 'CLITests/' AGENTS.md                             # expect >= 1
grep -c 'mainly `AuthPreamble.swift`' AGENTS.md           # expect 0
# every .swift file named in AGENTS.md exists somewhere in the repo:
for f in $(grep -oE '[A-Za-z]+\.swift' AGENTS.md | sort -u); do git ls-files | grep -q "/$f$" || echo "MISSING $f"; done
```
The last command prints nothing.

### Step 4: `README.md` — replace the "stores nothing" claims

1. Line 12. Replace `The app itself collects nothing and stores nothing.` with:

   ```markdown
   iMCP has no server of its own and no analytics. What it keeps on your Mac is
   listed under [Activate services](#activate-services).
   ```

2. Lines 155-158. Replace the whole `> [!IMPORTANT]` callout with:

   ```markdown
   > [!IMPORTANT]
   > iMCP sends your data to two places only: the MCP client you connect, which
   > _does_ send it off device as part of tool calls, and the Apple services a
   > tool calls (iCloud Find My, Maps, Weather).
   > It keeps a few things on this Mac: your settings, the fingerprints of
   > paired clients, and, once you sign in for Location, your Apple ID password
   > and iCloud session in the Keychain plus up to 90 days of location history.
   > See [iCloud sign-in and location history](#icloud-sign-in-and-location-history).
   ```

Before writing, confirm the storage facts still hold (another plan may have
changed retention or storage):

```console
grep -n 'var password' App/Services/Location/ICloudCredentialStorage.swift   # expect 1 line
grep -n 'location-history.sqlite' App/Services/Location/LocationHistoryStore.swift  # expect >= 1 line
grep -n '90 days' README.md                                                  # expect >= 1 line (the Location section)
```

If any returns nothing, STOP.

**Verify**:
```console
grep -c 'stores nothing' README.md                 # expect 0
grep -c 'collect or store any' README.md           # expect 0
grep -c 'Apple ID password' README.md              # expect >= 1
grep -c '(#icloud-sign-in-and-location-history)' README.md   # expect 1
grep -c '^### iCloud sign-in and location history$' README.md # expect 1
```

### Step 5: `README.md` — bring the capability table in line with the tools

Run the tool listing and group it by prefix:

```console
grep -rhoE 'name: "[a-z]+_[a-z_]+"' App/Services/*.swift | sort -u
```

At `8165d29` this prints the 52 names in "Current state" section B. If the
output differs (plan 054 adds update/delete tools), the live output wins.

Rule for every row of the `<table>` at `README.md:16-109`: the row's sentence
must mention every kind of action that service's tools perform. A tool whose
name ends in `_create`, `_update`, `_delete`, `_set`, `_ring`, or `_run`
changes something, and the row must say so with that verb (create, update,
delete, name, play a sound, run). Do not list tool names in the table. Do not
add or remove rows unless a service was added or removed in
`App/Controllers/ServiceRegistry.swift`.

Replacement `<td>` text for the rows that are wrong at `8165d29` (only the
description cell changes; leave the `<th>` icon cell and the name cell):

- **Calendar**: `List calendars, view events, create events with recurrence, alarms, and availability status, and delete events.`
- **Contacts**: `Look up your own contact card, search contacts by name, phone number, or email address, and create or update contacts.`
- **Location**: keep the existing sentence and insert before `See the <a href=`:
  `Also reads the location history iMCP records for your phone (stays, visits, and gaps), names places, and plays a sound on a device.`
  (and delete the words `and sound playback` from the first sentence if the
  result reads twice; the row must mention playing a sound exactly once).
- **Messages**: `Access message history with specific participants within customizable date ranges, including which conversation each message belongs to and a listing of its attachments.`
- **Notes**: `List Notes folders, search notes by title or content, optionally scoped to a folder, and read a note in full.`
- **Photos**: `Search the photo library by date, media type, and album with optional place-name enrichment, list albums, and fetch an image.`
- **Weather**: `Current conditions plus hourly, daily, and minute-by-minute forecasts for any location. Release builds only; a Debug build from source has no Weather service.`

For any tool in the live output that is not in section B's table, extend the
matching row by one clause using the rule above. For any tool in section B's
table that is no longer in the live output, remove the clause that describes
it. If a whole verb you were told to add (for example "delete events") has no
matching tool in the live output, leave it out.

**Verify** (run each only if the named tool is in the live grep output; all are
present at `8165d29`):
```console
grep -c 'delete events' README.md                  # events_delete      → expect 1
grep -c 'create or update contacts' README.md      # contacts_create/update → expect 1
grep -c 'read a note in full' README.md            # notes_fetch        → expect 1
grep -c 'fetch an image' README.md                 # photos_fetch_image → expect 1
grep -c 'minute-by-minute' README.md               # weather_minute     → expect 1
grep -c 'names places' README.md                   # location_place_set → expect 1
grep -c 'Release builds only' README.md            # expect 1
grep -c '<tr>' README.md                           # expect 16 (unchanged row count, unless a service was added or removed)
grep -c '</tr>' README.md                          # same number as the line above
```

### Step 6: `README.md` — fix the stale references

1. Line 122: delete the parenthetical so the sentence reads
   `First, [download the iMCP app](https://iMCP.app/download).` (The link
   installs the upstream build; its system requirement is not this repo's to
   state.)
2. In "Building from source", after the sentence
   `Debug builds do not require a provisioning profile.` (line 324), add:
   `The app requires macOS 15.1 or later.`
   Confirm first:
   `grep -c 'MACOSX_DEPLOYMENT_TARGET = 15.1' iMCP.xcodeproj/project.pbxproj`
   → `≥ 1`. If the project now uses another version for the `iMCP` target, write
   that version.
3. Line 312: change ``[`StdioProxy`](CLI/main.swift)`` to
   ``[`StdioProxy`](CLI/StdioProxy.swift)``. Confirm first:
   `grep -n 'actor StdioProxy' CLI/StdioProxy.swift` → 1 line.
4. Lines 326-333. Replace the sentence `From Terminal, use the same commands CI
   uses:` and its code block with:

   ````markdown
   From Terminal:

   ```console
   xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build
   Scripts/test.sh
   swift format lint --strict --recursive .
   ```

   `Scripts/test.sh` runs both test suites. It stops an installed
   `/Applications/iMCP.app` and its always-on watchdog first and restores them
   afterwards; running the `iMCP` scheme's tests directly fails while the
   installed app is running. `--app-only`, `--cli-only`, and
   `--only iMCPTests/<TestClass>` narrow the run.
   ````

5. Line 524: change ``the `fetchContacts` tool`` to
   ``the `contacts_search` tool``. Confirm first:
   `grep -c '"contacts_search"' App/Services/Contacts.swift` → `≥ 1`.
6. Lines 555 and 578 (both read
   `1. Click <img ... /> > "Copy server command to clipboard"`): replace the
   text after the `<img ... />` tag on each line with
   `> "Connect a Client…", then click **Copy** next to the server command`.
   Confirm first:
   `grep -c 'Connect a Client…' App/Views/ContentView.swift` → `≥ 1`.
   On line 584, `Paste the copied iMCP server command` stays as is.

**Verify**:
```console
grep -c 'macOS 15.0' README.md                         # expect 0
grep -c 'macOS 15.1' README.md                         # expect 1
grep -c '(CLI/main.swift)' README.md                   # expect 0
grep -c '(CLI/StdioProxy.swift)' README.md             # expect 1
grep -c '^xcodebuild test' README.md                   # expect 0
grep -c '^Scripts/test.sh$' README.md                  # expect 1
grep -c 'fetchContacts' README.md                      # expect 0
grep -c 'Copy server command to clipboard' README.md   # expect 0
```

### Step 7: `docs/plans/` — add a dated note to each of the three files

Insert the note as a blockquote on its own, with one blank line above and
below, directly under the `# ` title line of each file (line 1 in the first
file, line 9 in the second, line 8 in the third). Do not touch the YAML
frontmatter and do not change any other line.

Before writing, confirm the decision is still what the code does:

```console
git grep -n -i 'keep me signed in' -- App | wc -l                       # expect 0
git grep -n 'location_named_places\|location_name_place' -- App | wc -l # expect 0
grep -c 'name: "location_' App/Services/Location.swift                  # 11 at 8165d29; use the number printed
```

If the first prints non-zero, STOP. If the second prints non-zero, a rename
shipped after all: drop the rename sentence from note 1 and report it.

1. `docs/plans/2026-08-23-1559-location-find-my-rebuild-plan.md`:

   ```markdown
   > **Superseded in part (noted 2026-10-12).** This is the original design
   > record and is kept as written. Three things below no longer hold. (1) The
   > Apple ID password **is** persisted: by owner decision it is always stored
   > in the this-device-only data-protection Keychain item alongside the session
   > tokens, with no opt-in. The statements under "Settled decisions", unit B
   > "Persistence", and the forbidden list that it is never persisted are
   > historical. (2) The D4 renames did not ship; the tools are
   > `location_places` and `location_place_set`. (3) Location now declares 11
   > tools, not seven. Current behaviour is described in `README.md` under
   > "iCloud sign-in and location history".
   ```

   Replace `11` with the number the third command printed if it differs.

2. `docs/plans/2026-08-28-icloud-debug-session-durability-plan.md`:

   ```markdown
   > **Superseded in part (noted 2026-10-12).** Kept as written. "Passwords are
   > never persisted" (Goal Capsule, R4, and the verification list) no longer
   > holds: by owner decision the Apple ID password is always stored in the
   > this-device-only data-protection Keychain item alongside the session
   > tokens, with no opt-in. The rest of this plan stands.
   ```

3. `docs/plans/2026-09-02-icloud-session-survives-restart-plan.md`:

   ```markdown
   > **Decision (noted 2026-10-12).** Kept as written. R5 and U3 describe an
   > off-by-default "Keep me signed in" checkbox and a separate Keychain item
   > `co.dododo.iMCP.icloud-password`. Neither exists: by owner decision the
   > Apple ID password is always stored in the same this-device-only
   > data-protection Keychain item as the session tokens, with no checkbox. The
   > Status section below records the implementation.
   ```

**Verify**:
```console
grep -c 'noted 2026-10-12' docs/plans/2026-08-23-1559-location-find-my-rebuild-plan.md         # expect 1
grep -c 'noted 2026-10-12' docs/plans/2026-08-28-icloud-debug-session-durability-plan.md       # expect 1
grep -c 'noted 2026-10-12' docs/plans/2026-09-02-icloud-session-survives-restart-plan.md       # expect 1
head -1 docs/plans/2026-08-28-icloud-debug-session-durability-plan.md                          # expect ---
head -1 docs/plans/2026-09-02-icloud-session-survives-restart-plan.md                          # expect ---
git diff --numstat 8165d29 -- docs/plans/ | awk '{print $2}'                                   # expect 0 on every line (no deletions)
```

(If the base is not `8165d29` because other commits touched `docs/plans/`, use
`git diff --numstat HEAD -- docs/plans/` before committing instead.)

### Step 8: Final gate

```console
git status --porcelain
swift format lint --strict --recursive . ; echo "exit=$?"
```

**Verify**: `git status --porcelain` lists only the five in-scope files (or
nothing, if already committed, in which case
`git diff --name-only main...HEAD` lists only those five), and `exit=0`.

## Test plan

No automated tests: nothing compiled changes, and adding a doc-checking test
would be new code for a P3 docs fix. Verification is the `grep` assertions in
each step, including the existence loop in Step 3 that checks every `.swift`
file named in `AGENTS.md` is a real file.

Accuracy rule for the executor: every path, flag, tool name, and number you
write must be one a command in this plan printed from the live tree. Where the
live tree and this plan disagree, the live tree wins and you say so in your
report. Write less rather than guess.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c '^xcodebuild test' AGENTS.md README.md` → `0` for both files
- [ ] `grep -c 'side-effect-free' AGENTS.md` → `0`
- [ ] `grep -c 'main.swift` is the stdio proxy' AGENTS.md` → `0`
- [ ] `grep -c 'StdioProxy.swift' AGENTS.md` → `≥ 1`; same for `MCPService.swift`, `AlwaysOnHelper/`, `Packages/SRP/`, `CLITests/`
- [ ] The Step 3 existence loop prints nothing
- [ ] `grep -c 'stores nothing' README.md` → `0` and `grep -c 'collect or store any' README.md` → `0`
- [ ] `grep -c '(CLI/main.swift)' README.md` → `0`
- [ ] `grep -c 'macOS 15.0' README.md` → `0`
- [ ] `grep -c 'fetchContacts' README.md` → `0`
- [ ] `grep -c 'Copy server command to clipboard' README.md` → `0`
- [ ] `grep -c 'Release builds only' README.md` → `1`
- [ ] `grep -c '<tr>' README.md` equals `grep -c '</tr>' README.md`
- [ ] `grep -l 'noted 2026-10-12' docs/plans/*.md | wc -l` → `3`
- [ ] `git diff --name-only main...HEAD` (or `git status --porcelain` before committing) lists only the five in-scope files
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `plans/README.md` is unmodified

## STOP conditions

Stop and report back (do not improvise) if:

- `grep -n 'var password' App/Services/Location/ICloudCredentialStorage.swift`
  returns nothing, or `git grep -i 'keep me signed in' -- App` returns a match.
  The owner decision this plan records would then not match the code, and the
  notes in Step 7 and the callout in Step 4 would be wrong.
- `grep -n 'SIGTERM' Scripts/bench-full-stack-performance.mjs` returns nothing.
  The benchmark no longer kills the app and Step 2's wording needs a decision.
- `Scripts/test.sh` no longer exists or no longer accepts `--only`. Steps 1 and
  6 document it as the only test entry point.
- `CLI/StdioProxy.swift` does not exist or does not declare `StdioProxy`
  (another plan moved the proxy).
- A step seems to need a change to a file outside the five in scope, including
  a Swift comment, a script's `--help` text, or `plans/README.md`.
- A quoted sentence a step replaces cannot be found in the live file even after
  searching for its key phrase (`grep -n 'stores nothing' README.md`, and so
  on) and the claim it made is not present in other words either. If the claim
  is already gone, skip that sub-step and report it; that is not a STOP.
- A step's verification fails twice after a reasonable fix attempt.

## Maintenance notes

- **Sequencing.** This plan is deliberately last. If it runs early, Step 5's
  table goes stale as soon as plan 054 lands its update/delete tools; re-run
  Step 5 alone afterwards.
- **For plan 050 (script safety).** If 050 changes the benchmark to match
  processes by executable path, the Step 2 sentence stays true (it still
  terminates the installed app). If 050 removes the startup measurement
  altogether, delete the Step 2 sentence. If 050 deletes orphan scripts, the
  Step 3 loop only checks `.swift` names, so check `AGENTS.md`'s `Scripts/`
  bullet by hand against `ls Scripts`.
- **For plan 045 (iCloud sign-in).** The comment at
  `App/Services/Location/ICloudCredentialStorage.swift:5-9` still says the
  password is never written. This plan does not fix it; the three doc notes and
  that comment should agree once both land.
- **For plan 048 (Settings).** About-box links pointing at upstream are code,
  not docs, and are not fixed here.
- **Not fixed, noted for the owner.** `README.md:224` suggests "How's the
  weather where I am?" as a first question, but Weather exists only in Release
  builds and Location reports the phone, not the Mac. `README.md:322` says
  source builds "use Xcode 26 on macOS 26 in CI", which is still true. The
  `> [!NOTE]` at `README.md:113-117` (download installs upstream) is still
  true and was left alone.
- **Reviewer focus.** Read the new `> [!IMPORTANT]` callout against the
  "Stored locally" list in this plan, and the seven rewritten table rows
  against the live tool listing. The failure this plan fixes is docs drifting
  from code, so the review is a diff against `grep`, not against taste.
- **Installing.** Nothing here needs an install. Do not run
  `Scripts/install-local.sh run` for this plan unless the operator asks.
- **Human steps.** None.
