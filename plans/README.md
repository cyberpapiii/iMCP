# iMCP Improvement Plans

Self-contained implementation plans produced by advisory audits of iMCP.
Plans **001–018** were written at commit **`b84f266`** (2026-07-02). Plans
**019–021** were written at commit **`5caccce`** (2026-07-06) after a second
audit pass and maintainer review. Each plan is written to be executed by a
separate model with **no context from the audit session** — read the whole plan
before starting, run every verification command, and respect its STOP conditions.

## How to use this directory

1. Pick the lowest-numbered `TODO` plan whose dependencies are `DONE`.
2. Run the plan's **Drift check** first — each plan cites its **Planned at**
   commit; if the cited file has changed, reconcile before editing.
3. Follow the steps; each has a verification command and expected output.
4. Update this plan's **Status** row below when you finish (or mark `BLOCKED`
   with a note).

**Ground rules for every plan**: only touch the files listed in that plan's
*In scope*; run `Scripts/lint.sh --fix` before finishing (CI gates on
`swift format lint --strict --recursive .`); the build treats warnings as errors;
do not push or open PRs unless the operator asks.

For quiet Xcode build commands, success is exit code 0; `-quiet` may suppress
the `** BUILD SUCCEEDED **` marker.

**Test targets are synchronized folders.** `iMCPTests/`, `CLITests/`,
`CLI/`, and `Shared/` are `PBXFileSystemSynchronizedRootGroup`s, so a test or
shared source file on disk joins its targets with no `project.pbxproj` edit.
(Until November 2026 the test targets were hand-listed, which is how three test
files went unrun for months, plan 030.)

**Running the app-test gate on this machine**: `xcodebuild test -scheme iMCP`
fails with `IDELaunchErrorDomain` code 20 ("The LaunchServices launcher has
returned an error") whenever the installed `/Applications/iMCP.app` is running,
because it shares the bundle identifier `co.dododo.iMCP` with the test host.
It is an environment collision, not a product defect. Do not `pkill` the app
or run the scheme's tests directly: the always-on watchdog relaunches it at
once. Run `Scripts/test.sh` (optionally `--only iMCPTests/<Class>`), which
pauses the watchdog, stops the app, and restores both.

## Repo-wide commands (used across plans)

| Purpose | Command |
|---------|---------|
| Build | `Scripts/install-local.sh build` (compiles into the `.build/DerivedData` tree `Scripts/test.sh` shares; leaves the installed app alone) |
| CLI tests | `Scripts/test.sh --cli-only` |
| Both test suites (use this, not `xcodebuild test -scheme iMCP`: the always-on watchdog breaks the app test host) | `Scripts/test.sh` |
| Format (write), then lint | `Scripts/lint.sh --fix` |
| Format lint (CI gate) | `Scripts/lint.sh` |

## Status table

| # | Plan | Category | Priority | Effort | Risk | Depends on | Status |
|---|------|----------|----------|--------|------|-----------|--------|
| 001 | [Fix `events_create` end-date normalization](001-fix-event-end-date.md) | bug | P1 | S | LOW | — | DONE |
| 002 | [Apply date range + cap to `reminders_fetch`](002-fix-reminders-date-filter.md) | perf | P1 | S | LOW | — | DONE |
| 003 | [README: real services & tool count](003-update-readme-services-tools.md) | docs | P1 | S | LOW | — | DONE |
| 004 | [Run the test suite in CI](004-ci-run-tests.md) | tests | P1 | S | LOW | — | DONE |
| 005 | [Add CLAUDE.md / AGENTS.md + build docs](005-add-agent-and-contributor-docs.md) | dx | P2 | S | LOW | — | DONE |
| 006 | [LocationService concurrency + on-demand fetch](006-fix-location-concurrency.md) | bug | P2 | M | MED | — | DONE |
| 007 | [Shortcuts process race + pipe deadlock](007-fix-shortcuts-process-handling.md) | bug | P2 | S | LOW | — | DONE |
| 008 | [Guard `capture_record_audio` continuation](008-fix-capture-audio-continuation.md) | bug | P2 | S | LOW | — | DONE |
| 009 | [Snapshot service enablement on MainActor](009-snapshot-service-enablement.md) | bug | P2 | M | MED | — | DONE |
| 010 | [Stop `messages_fetch` over-fetching](010-fix-messages-fetch-limit.md) | perf | P2 | S | MED | — | DONE |
| 011 | [Single-encode tool results](011-single-encode-tool-results.md) | perf | P2 | M | MED | — | DONE |
| 012 | [Cache tool definitions](012-cache-tool-definitions.md) | perf | P3 | M | LOW | 009, 013 | DONE |
| 013 | [Split `ServerController.swift` + log fix](013-split-servercontroller.md) | tech-debt | P3 | L | MED | 009 | DONE |
| 014 | [Extract + test config merge (App test target)](014-extract-and-test-config-merge.md) | tests | P2 | L | MED | — | DONE |
| 015 | [Security trust-boundary spike (design)](015-security-trust-boundary-spike.md) | security | P1* | L | HIGH | — | DONE |
| 016 | [Disable name-only persistent client auto-trust](016-disable-name-only-auto-trust.md) | security | P1 | S | MED | — | DONE |
| 017 | [Make CLI Bonjour endpoint selection fail closed](017-require-unambiguous-imcp-bonjour.md) | security | P1 | S | MED | — | DONE |
| 018 | [Bound `maps_generate` snapshot dimensions](018-bound-map-snapshot-size.md) | perf | P2 | S | LOW | — | DONE |
| 019 | [Quick wins: tool errors + README services](019-quick-wins-trust-and-docs.md) | security | P1 | S | LOW | — | DONE (`a70d79c`; Photos step invalid — rejected #9) |
| 020 | [Test CLI Bonjour endpoint selection](020-test-cli-bonjour-selection.md) | tests | P1 | S | LOW | — | DONE (`815767f`) |
| 021 | [Test connection approval queue + tool gating](021-test-connection-approval-spine.md) | tests | P1 | M | MED | — | DONE (`40653ea`) |
| 022 | [Route CallTool through cached tool map](022-calltool-cache-dispatch.md) | perf | P2 | M | MED | — | DONE (`83fd87f`) |
| 023 | [Remove CLI network read busy-polling](023-cli-network-read-no-poll.md) | perf | P2 | M | MED | — | DONE (`2db1d34`) |
| 025 | [Paired-client trust store (fingerprint-keyed)](025-paired-client-trust-store.md) | security | P1 | M | LOW | — | DONE (`f463e8c`) |
| 026 | [Auth preamble: signed nonce over existing channel](026-auth-preamble-signed-nonce.md) | security | P1 | L | MED-HIGH | 025 | DONE (`d0eb3ad`) |
| 027 | [Pairing UX: one-time code + pair-on-approve](027-pairing-ux.md) | security | P2 | M | MED | 025, 026 | DONE (`a254f08`) |
| 028 | [Pairing hardening: rotation, reset, docs](028-pairing-hardening.md) | security | P3 | S-M | LOW-MED | 025–027 | DONE (`5a1f3eb`) |
| 029 | [Establish a green verification baseline](029-verification-baseline.md) | tests | P1 | S | LOW | — | **DONE** (branch `advisor/029-verification-baseline`, merged into `main`) |
| 030 | [Wire the three orphaned test files into the target](030-wire-orphaned-tests.md) | tests | P1 | S | LOW | 029 | **DONE** (branch `advisor/030-wire-orphaned-tests`, merged into `main`; app tests 94 → 105) |
| 031 | [Restrict the listener endpoint handoff file](031-harden-listener-endpoint-file.md) | security | P1 | S | LOW-MED | 029 | **DONE** (branch `advisor/031-harden-listener-endpoint-file`, merged into `main`; 5 new tests) |
| 032 | [Consolidate the paired-client trust store](032-consolidate-paired-client-store.md) | security | P1 | M | MED | 029, 030 | **DONE** (branch `advisor/032-consolidate-paired-client-store`, merged into `main`; contains 030 merged in — app tests 105 → 107, 2 new tests) |
| 033 | [Capture: activation, delay timeout, display, payload bound](033-capture-service-fixes.md) | bug | P2 | M | MED | 029 | **DONE** (branch `advisor/033-capture-service-fixes`, merged into `main`; app tests 94 → 100, 6 new tests) |
| 034 | [Utilities reachable, no key clobber, badge refresh](034-small-correctness-batch.md) | bug | P2 | S | LOW | 029 | **DONE** (branch `advisor/034-small-correctness-batch`, merged into `main`; app tests 94 → 95, CLI tests 24 → 27) |
| 035 | [Docs truth pass: install path, signing, Key Paths](035-docs-truth-pass.md) | docs | P2 | S | LOW | — | **DONE** (branch `advisor/035-docs-truth-pass`, merged into `main`) |
| 036 | [Prompt-free, fast developer loop](036-developer-experience.md) | devex | P1 | M | LOW | — | **DONE** (prompt-free install, 324 app tests in 4.5 s, build-once CI) |
| 037 | [Tests never touch real state; test scripts cannot leave iMCP down](037-isolate-tests-from-real-state.md) | tests | P1 | M | MED | — | DONE |
| 038 | [Validate tool arguments in one place](038-validate-tool-arguments.md) | bug | P1 | L | MED | 037 | DONE |
| 039 | [True MCP annotations on every tool, pinned by one test](039-correct-tool-annotations.md) | bug | P1 | S | LOW | — | DONE |
| 040 | [Location tools: newest history, valid places, right device, no raw errors](040-location-tool-correctness.md) | bug | P1 | M | MED | 037, 038 | DONE |
| 041 | [`contacts_update` changes only what it is asked to change](041-contacts-update-data-loss.md) | bug | P1 | S | LOW | 037 | DONE |
| 042 | [Tool failures say what to do; tool calls open no dialogs](042-actionable-tool-errors.md) | bug | P1 | M | MED | 037 | DONE |
| 043 | [Connection setup, pairing, and Debug trust store hardening](043-connection-pairing-security.md) | security | P1 | L | MED | 037 | DONE |
| 044 | [CLI delivers the last reply, never reconnects mid-session, shares one frame scanner](044-cli-reliability-shared-framing.md) | bug | P2 | M | MED (step 5 HIGH, separable) | 037, 043 | DONE |
| 045 | [iCloud sign-in reliability and password handling](045-icloud-signin-reliability.md) | bug | P1 | M | MED | 037, PR #61 merged | DONE |
| 046 | [Find My People: fail closed, clean up, survive transient faults](046-find-my-people-hardening.md) | security | P2 | M | MED | 037, PR #61 merged | DONE (Part A; Part B, the Find My People setup scripts, needs the owner at the keyboard) |
| 047 | [Location window reloads only on change; cancelled sampler tick reports nothing](047-location-window-sampler.md) | perf | P2 | M | MED | 037, 040 | DONE |
| 048 | [Settings and menu tell the truth, with less code](048-settings-menu-fixes.md) | bug | P2 | M | LOW | 037, PR #61 merged | DONE |
| 049 | [Service bugs fixed by deleting and consolidating](049-service-bugs-simplification.md) | tech-debt | P2 | L | MED | 038, 042 | DONE |
| 050 | [Release, ship, install, doctor, and benchmark scripts fail safe](050-script-safety.md) | bug | P1 | M | MED | 037 | DONE |
| 051 | [Deletion sweep: Sparkle residue, inert entitlements, orphan scripts](051-deletion-sweep.md) | tech-debt | P2 | M | MED | 037 | DONE |
| 052 | [CI: pinned actions, script lint, Release compile](052-ci-hardening.md) | dx | P2 | S | LOW | 050, 051 | DONE |
| 053 | [AGENTS.md, README, and old design docs match the code](053-docs-accuracy.md) | docs | P3 | S | LOW | run last | DONE |
| 054 | [Edit and delete reminders, reschedule events, delete a named place](054-write-verbs.md) | direction | P3 | M | MED | 038, 039, 041 | DONE |

Number 024 was consumed by the unplanned reliability-backlog batch
(`advisor/024-reliability-backlog`: approval TTL, health-monitor cancel,
geocode LRU) — no plan doc exists for it by design.

\* Plan 015 is high-priority as a security concern but is scoped as an
investigation/design spike, not a build — it produces a design doc and a phased
proposal, not shipped auth code.

## Recommended execution order

The plans are numbered in a sensible default order. Notes:

- **Quick wins first (001–005)** — small, low-risk, independent. 001/002 fix
  user-visible correctness/perf bugs; 003/005 are docs; 004 turns on CI testing.
  Good warm-up and immediately valuable.
- **Concurrency hardening (006–009)** — each is independent and self-contained.
  006 (Location) and 009 (enablement race) are the meatier ones. 007/008 are
  small continuation-leak fixes following the repo's existing `ResumeGate` pattern.
- **`ServerController.swift` trio — order matters**: do **009 → 013 → 012**.
  Fix the enablement race in place (009), then the structural split (013), then
  add the tool-definition cache (012) in the settled structure. All three touch
  the same file; sequencing them avoids rebasing churn.
- **Perf (010, 011)** — independent of the above; can slot in anytime.
- **014 (config-merge + App test target)** is the enabler for automated tests:
  plans 001, 002, 007, 008, 010, 011, 012 all *defer* their unit tests until an
  App test target exists, and 014 creates it. Plan 006 remains manual/compiler
  verified because delegate-driven location testing needs a fake location
  manager seam that is out of scope there. Doing 014 earlier lets the eligible
  plans add real tests instead of manual-only verification; doing it later is
  fine too (their fixes don't depend on it). After 014, revisit 004 to add the
  App test scheme to CI.
- **Security immediate mitigations (016-017)** can land before the larger
  security design. 016 removes the name-only persistent auto-trust bypass; 017
  removes the CLI's arbitrary Bonjour first-result fallback.
- **015 (security spike)** is still independent and should run even if 016-017
  land first. Its output is the durable client identity/channel design, so
  starting it early surfaces the security roadmap sooner. In this branch, the
  original approval-gate ordering issue has already been corrected; the spike
  records the remaining identity and transport work as future plans.

### Dependency graph (edges = "must land before")

```
009 ──▶ 013 ──▶ 012
014 ──▶ (enables tests in) 001 002 007 008 010 011 012
004 ◀── (revisit after) 014     # add App test scheme to CI
```

Everything not shown is independent.

### Second audit pass (019–023)

Recommended order after maintainer review:

1. **019** — error sanitization + README (`a70d79c`). ~~Photos `.readOnly`~~ invalid.
2. **020** — Bonjour selection tests (`815767f`); regression for pre-`d53b9a1` fail-always.
3. **021** — approval queue + tool gating tests (next).
4. **022 → 023** — perf pair: CallTool cache dispatch, then CLI idle polling.

**Backlog cleared 2026-07-06 (advisor/024-reliability-backlog)**: approval TTL
(120s auto-deny, `ServerController`), health monitor cancellation
(`MCPConnectionManager`), geocode LRU cap (`PlaceNameCache`, 512 entries).
Pairing phase 1 from `plans/notes/015-security-trust-boundary-design.md`
(handler-level approval gate on `ListTools`/`CallTool`) already landed via
plan 021 tests; remaining pairing phases (trust store, CLI pairing bootstrap,
signed nonce, TLS-PSK, migration) await maintainer/product decisions listed in
the design doc's Open Questions. Note: the doc's phase numbers 019–024 are
stale — those plan numbers were consumed by other plans; renumber when planned.

**Cleared 2026-07-06 (`fc769e5`)** — stale bookmark refresh (clear-on-failure
with default-path fallback) and capture delegate clobber (#5, gate actor +
delegate no longer stored on shared property).

**Still open** — pre-commit hook (#16), upstream Files/Music branches.

### Third audit pass (029–035)

Written at commit **`17d7c72`** (2026-08-07), scoped mainly to the code that
landed after the last audit (`16972ea..HEAD`): the permissions UI, the Capture
rewrite, the CLI loopback fast path, and the pairing subsystem from 025–028.

**Do 029 first.** `gh run list -R cyberpapiii/iMCP` returns zero runs — this
fork is 67 commits ahead of `origin/main` and 0 behind, and none of those 67
commits has been through the lint/build/test gate. Every other plan's
verification section assumes those commands pass; 029 makes that true (or finds
out it isn't) before anything else is judged against it.

Recommended order:

1. **029** — verification baseline. Blocks everything.
2. **030** — three test files (`PairedClientStoreTests`, `PlaceNameCacheTests`,
   `ToolErrorSanitizationTests`) exist on disk but are in **no** target and have
   never run — including the regression tests for work marked DONE above.
3. **031, 034, 035** — independent and small; can run in any order or in
   parallel. 035 is docs-only and depends on nothing.
4. **032** — trust-store consolidation. Wants 030 first, because
   `PairedClientStoreTests` is its safety net.
5. **033** — Capture batch; independent of the security work.

### Dependency graph, third pass (edges = "must land before")

```
029 ──▶ 030 ──▶ 032
  ├───▶ 031
  ├───▶ 033
  └───▶ 034
035 (independent)
```

**Plan selection was the non-interactive default.** This audit ran without a
user available to choose which findings became plans, so the seven highest-
leverage vetted findings were planned automatically. Everything else that
survived vetting is listed under "Open, unplanned findings from the third
audit" below, and everything that did not survive is in the rejected table —
neither list needs re-auditing next run.

## Scope note

Plans **001–018** covered the first audit. The **2026-07-06** re-audit produced
**019–023** (quick wins, tests, perf pair). The **2026-08-07** third audit
produced **029–035**.

## Direction options (third audit — not plans, maintainer decisions)

Grounded but unscoped; each needs a decision before a plan is worth writing.
Recorded so they are not re-derived next pass.

- **MCP Resources.** `ListResources` is stubbed to return an empty list
  (`App/Controllers/ServerNetworkManager.swift:473-476`), next to an equally
  stubbed `ListPrompts`. Upstream's unmerged `origin/mattt/files-service` branch
  already built the plumbing (`App/Models/Resource.swift`, a `resourceTemplates`
  property on `Service`). This is the fix for image payloads generally: photos
  and screenshots become referenceable URIs instead of base64 blobs inlined into
  tool results. Needs reconciliation with the plan-013 controller split. **Open
  question**: must resources respect the same per-connection approval gate tools
  do?
- **Per-client service scoping.** `PairedClient`
  (`App/Models/PairedClient.swift:10-16`) has a durable cryptographic identity
  but no notion of what it may reach; both gates
  (`ServerNetworkManager.swift:485-500`, `:514-542`) check only "approved" plus
  the global enabled-services set. So enabling Messages for one agent enables it
  for every paired client. Plans 025–028 already paid for the hard part. Best
  ratio of evidence to cost of the six.
- **Port the Music service.** `origin/mattt/music` has a 536-line
  `App/Services/Music.swift`; every prerequisite it needed (Apple Events
  entitlement, usage string, the `AEDeterminePermissionToAutomateTarget` probe
  pattern in `App/Services/Notes.swift:57-76`, an Automation row in the
  permissions UI) already exists here, solved independently for Notes.
- **Files service.** `origin/mattt/files-service` has a 222-line implementation,
  and this fork has four mature security-scoped-bookmark implementations to
  model on. **Highest security surface of the six** — a path-scoped reader in a
  non-sandboxed app holding Full Disk Access. Should not ship before per-client
  scoping exists, and the access model (explicit bookmark-granted roots, never
  "any path with FDA") must be settled first.
- **Fill in write verbs.** Reminders has create/fetch/lists but nothing to
  complete or edit; Calendar has create but no update or delete; Notes has
  working AppleScript write plumbing (`App/Services/Notes.swift:82`) but no
  create. Contacts is complete, which shows the asymmetry is incidental rather
  than a read-only policy. **Open question**: do destructive tools need their own
  confirmation gate, separate from connection approval? That answer also shapes
  the scoping model above.
- **Tool-call activity log.** Every invocation already passes through one choke
  point that logs it (`ServerNetworkManager.swift:504-542`), but nothing tells
  the user *what was read*. Pairing answers "who may connect"; this answers the
  other half. Would need to record tool names and timestamps only — never
  arguments or results — with a bounded size.

## Findings considered and rejected (second audit)

| Finding | Verdict |
|---------|---------|
| Photos `.readOnly` authorization (#9) | **Invalid** — `PHAccessLevel` has only `.addOnly` and `.readWrite`; `.readWrite` is minimum for read. Plan 019 step skipped at `a70d79c`. |
| Bonjour `"iMCP"` substring "mitigated" | **Was fail-always until `d53b9a1`** — app advertises `name: "iMCP"`; plan **020** landed tests at `815767f`. |
| `removedConnections` unbounded growth | **Fixed** — transient `removingConnections` with `defer` in `ServerNetworkManager`. |
| `listShortcuts` stderr deadlock | **Fixed** — concurrent stderr drain in `Shortcuts.swift:135-140`. |
| Messages read-write entitlement | **Not present** in current entitlements plists. |
| Health monitor task leak (#10) | **Confirmed and fixed** (advisor/024) — task was unstored; lingered up to one 30s cycle after stop. Now stored and cancelled in `stop()`. |
| Photos geocode cache unbounded (#11) | **Fixed** (advisor/024) — `PlaceNameCache` now LRU-capped at 512 with tests. |
| Capture photo delegate clobber (#5) | **Real but rare** — concurrent captures from one client uncommon; defer. |
| Local pre-commit hook (#16) | **Optional DX** — CI already gates format; defer. |
| Approval TTL (#13) | **Landed** (advisor/024) — unanswered approval prompts auto-deny after 120s via the `cancelApproval` spine; queued approvals promote. |
| Pairing spike / upstream merges | **Direction** — not bugs; see `015-security-trust-boundary-design.md`. |

## Findings considered and rejected (third audit, 2026-08-07)

| Finding | Verdict |
|---------|---------|
| SwiftUI `@State` written off the main actor in `ContentView`/`ServiceToggleView`/`SettingsView` | **Invalid** — SwiftUI's `View` protocol is declared `@preconcurrency @MainActor` (verified in the macOS 26 SDK `SwiftUICore.swiftinterface`), so a conforming struct's members — and the bodies of bare `Task {}`s inside them — are MainActor-isolated. The helpers are already on the main actor; nothing to fix. Note for anyone re-checking: `View` moved from `SwiftUI` to `SwiftUICore` at macOS 15, so grepping `SwiftUI.swiftinterface` for `protocol View` finds nothing and makes the isolation look absent. Look in `SwiftUICore.framework/.../arm64e-apple-macos.swiftinterface`. |
| New `files.user-selected.read-write` entitlement is a security change | **Inert** — `ENABLE_APP_SANDBOX = NO` (`project.pbxproj:734`, `:800`), so the entitlement neither grants nor restricts anything. It is residue, not a grant. See the sandbox row below. |
| `computedServiceConfigs` rebuilt per access (15 × `String(describing:)`) | **Not worth doing standalone** — real mechanism, negligible cost at menu-bar interaction rates. Fold into a permission-cache change if one is ever made. |
| `Scripts/install-local.sh` verify-then-install gap | **Marginal** — staging dir is inside `/Applications`, but the script re-verifies the installed bundle afterward, and on a single-admin machine the attacker already has equivalent write access. Hardening, not a hole. |
| Pairing-code brute force | **Low severity** — 6–8 chars over a 32-symbol alphabet inside a 5-minute window is ≥2^30; not practically guessable. Worth an attempt cap and a constant-time compare only if the alphabet or lifetime ever shrinks. |
| README capabilities table stale | **Verified accurate** — all 16 rows match the registered services and their ~40 tools. Do not re-audit. |
| `NWConnectionTransportTests` real sockets + fixed sleeps | **Leave it** — every test is wrapped in a 5s timeout helper and the sleeps are chunk-boundary setup, not synchronization. Its real weakness is being the *only* coverage of app-side framing. |
| `NWConnectionTransport.connect()` returns instead of throwing when `disconnect()` raced it (`:129-131`) | **By design** — the only way to reach that `return` is through `disconnect()`, which has already set `state = .stopped`, cancelled the connection, and called `messageContinuation.finish()` (`:144-154`). The caller's message stream is therefore already finished, so it shuts down promptly; it does not hang waiting on a dead transport. Throwing here would turn a clean teardown into a logged error. |

### Open, unplanned findings from the third audit

Recorded with evidence so they are not re-derived. **Reconciled by the fourth
audit (2026-10-12): see "Fourth audit pass (037–054)" at the end of this file
for which of these are fixed, planned, or still open.** Line numbers below are
as of the third audit and are stale.

- **App Sandbox disabled at `17d7c72`** with the sandbox-only entitlements left
  in place (`com.apple.security.inherit`, the seven-path
  `temporary-exception.files.absolute-path.read-only` array,
  `files.user-selected.read-write`). The disabling appears deliberate — the
  README records that FDA-protected databases stay blocked by the sandbox even
  after the TCC grant — but the residue makes the signed bundle look more
  constrained than it is, and `Scripts/verify-app-signing.sh:52-55` now asserts
  the *inert* entitlement as if it were meaningful. Cleanup is S; genuinely
  restoring the boundary (an unsandboxed XPC helper for FDA reads) is L.
- **Server is not authenticated to the CLI.** `CLI/main.swift:518-529` signs any
  `AUTH-CHALLENGE` it receives, and the signed payload
  (`App/Shared/AuthPreamble.swift:55-60`) is `nonce ‖ connectionID` — both
  chosen by the challenger, nothing binding it to a socket or server key. Plan
  031 closes the file-trust half; this is the protocol half and needs a
  coordinated wire-format change.
- **Trust store lives in `UserDefaults`** in a non-sandboxed app, so any
  same-user process can inject a fingerprint and get silent permanent access.
  Plan 032 consolidates to one owner as the prerequisite; the Keychain (or
  HMAC-under-a-Keychain-key) migration is the follow-up.
- **CLI terminates instead of falling back to Bonjour** when a stale endpoint
  file names a recycled port: `StdioProxyError.connectionClosed` is treated as
  "session was established" (`CLI/main.swift:667-681`) but also fires on the
  first failing read. Needs a session-established signal from `StdioProxy`.
- **Approval dialog renders the client-supplied name unsanitized** — no length
  cap, no newline stripping, in a fixed 420×300 frame
  (`App/Views/ConnectionApprovalView.swift:32`, `:68`) — and a client whose
  signature **failed verification** looks identical to one that presented no key
  (`:34-39`; the `invalidSignature` outcome at
  `ServerNetworkManager.swift:248-252` never reaches the UI). This dialog is the
  entire boundary for unpaired clients.
- **Permission probes fan out three ways with no cache** — menu rows, the FDA
  banner (which loops *serially*), and Settings rows — several duplicated per
  menu open, each probe resolving a security-scoped bookmark.
- **`CLI/main.swift` is 822 lines of top-level code**, so none of it is
  importable by `imcp-serverTests`: the loopback/`skipLoopback` state machine,
  `selectIMCPEndpoint`, and the auth-challenge loop are untestable by
  construction. Also: a 10 MB buffer is allocated and zero-filled *inside* the
  stdin event handler (`:64-66`) on every read, and the doc comment still claims
  a 4096-byte default.
- **Message framing is implemented twice** — `CLI/MessageFrameScanner.swift`
  (12 unit tests) and an inline copy in
  `App/Controllers/NWConnectionTransport.swift:207-265` (no unit tests). The
  CLI file's own comment says it mirrors the app. `App/Shared/AuthPreamble.swift`
  shows the repo already has the share-one-file mechanism.
- **Pre-authenticated auto-approve is untested**, and the test named for it
  (`iMCPTests/ServerNetworkManagerAuthTests.swift:148-160`) asserts the state it
  just set rather than the approval closure at
  `ServerNetworkManager.swift:407-413`.
- **`iMCPTests/ClaudeDesktopConfigTests.swift` holds five unrelated test
  classes** and has become the junk drawer — likely why the Capture rewrite
  added no tests (its only coverage is buried there).
- **Dead code in `Capture.swift`**: `captureSession`/`audioRecorder`/`photoOutput`
  (`:35-37`) are never assigned, so the `deinit` at `:44-48` performs no cleanup
  while appearing to; `resumeOnce` takes a cleanup closure it discards (`:482-487`).
- **CI gaps**: the DerivedData cache key can never refresh after its first hit
  (`actions/cache` saves only on a key miss), and `WEATHERKIT_AVAILABLE` is set
  only in the app target's Release config (`project.pbxproj:852`) while CI
  builds Debug — so all of `App/Services/Weather.swift` is never compiled by CI.
- **`Scripts/release.sh` has no `-R` flag** on its `gh release create` /
  `upload` calls (`:410`, `:426`) while `origin` is the read-only upstream —
  it would resolve the target repo ambiguously *after* archiving and notarizing.
- ~~**`location_reverse-geocode`** was the only tool name using a hyphen.~~
  RESOLVED: the Location CoreLocation service was deleted and the tool moved to
  `App/Services/Maps.swift` as `maps_reverse_geocode`; every tool name is now
  snake_case.
- **Two script directories**, `Scripts/` and lowercase `script/`, ambiguous on a
  case-insensitive filesystem; neither is exercised by CI (`shellcheck` would
  be the realistic gate, since signing needs an identity runners lack).
- **Window controllers are owned by the menu view.**
  `App/Views/ContentView.swift:11` holds `AboutWindowController` in a stored
  `let` assigned in `init` (`:35`), and `ContentView` is the `MenuBarExtra`
  content (`App/App.swift:12`), so SwiftUI re-inits the struct on every
  invalidation — including each `isMenuPresented` flip. `AboutWindowController`'s
  convenience init eagerly builds an `NSWindow` + `NSHostingView` (`AboutWindow.swift:5-18`),
  so a whole window is allocated and discarded per menu open/close, and "About
  iMCP" (`ContentView.swift:134`) shows *this* struct's instance — a second open
  after a re-init produces a second window rather than raising the first
  (`isReleasedWhenClosed = false`). `@State private var pairClientWindowController`
  (`:12`) has the right ownership form but is assigned *after* an await
  (`:100-110`) while `MenuButton` has already dismissed the menu (`:243-259`);
  the window itself survives because `NSApp` retains ordered-in windows, so the
  practical risk there is a dropped controller reference, not a vanishing
  window. Fix is S: `@State` (or app-level ownership) for both, with lazy window
  construction.
- **`@State private var fullDiskAccessGranted = FullDiskAccess.isGranted`**
  (`App/Views/SettingsView.swift:54`) runs an `open(2)` probe of the TCC
  database (`App/Models/FullDiskAccess.swift:14-20`) in a `@State` *default
  expression*, which SwiftUI evaluates on every struct init while keeping only
  the first result. So it is a syscall per invalidation whose value is
  discarded; `refresh()` (`:113-116`) is what actually keeps the flag current.
  Initialize to `false` instead. S, low impact.
- **Auth frame extension is inferred from a value range** rather than an explicit
  marker (`App/Shared/AuthPreamble.swift:171-192`): a trailing byte whose value
  falls in the pairing-code length range is parsed as a code. Latent today —
  becomes a real defect the moment a second extension or padding is added.

## Fourth audit pass (037–054)

Written 2026-10-12 at commit **`8165d29`** (branch `feat/menu-bar-resilience`,
PR #61). `origin/main` carried one extra commit touching `CLI/`; plans that
edit `CLI/` are based on the `origin/main` text. Every plan was written from a
fresh read of the cited code. **Nothing was built, run, or measured**: all
findings come from reading, and test code inside the plans has not been
compiled.

Owner preference applied throughout: fix by simplification, consolidation, and
deletion rather than by adding code. Estimated net effect across the set is a
few hundred fewer source lines, plus roughly 100 new tests.

### Execution order

1. **037 first.** It makes the app test host inert and fixes `Scripts/test.sh`;
   every other plan verifies through it. 043 has a hard STOP without it.
2. **Merge PR #61** before 045, 046, 048 (they STOP if `8165d29` is not an
   ancestor of `HEAD`).
3. Then the P1 group, any order unless noted: 039, 041, 042, 038, 045, 050, 043.
4. 040 (after 038), 047 (after 040), 044 (after 043), 049 (after 038 and 042),
   046, 048, 051.
5. 052 (after 050 and 051), 054 (after 038, 039, 041).
6. **053 last**: it documents what actually landed.

Run one plan at a time. Many plans touch the same files (`Location.swift`,
`SettingsView.swift`, `ServerNetworkManager.swift`, `ICloudSignInWindow.swift`);
each anchors on quoted code and has a drift check, but parallel branches will
conflict.

### Cross-plan interactions

- 039 pins every tool's annotations in one table test. 040/047 and 054
  (four new tools) must update that table. 049 keeps the photo reverse-geocode,
  so `photos_search` stays open-world.
- 040 changes `location_history` output from a bare array to
  `{"samples": [...], "truncated": Bool}`.
- 040 uses 042's error-sanitising helper if 042 is DONE, otherwise an inline
  equivalent.
- 037 deletes the tautological auto-approve test; a real test of that path is
  left to 043.
- 046 swaps three duplicate keychain result enums in files owned by 043 and 045
  (enum swap only).
- 050 changes `ship.sh` so untracked files stop the run; new files must be
  staged with `git add` first.
- 045 and 048 both add or touch Sign Out controls; treat both buttons alike.

### Steps only the owner can do

No plan asks an agent to type the Apple ID password or a 2FA code, change
System Settings, or run the Find My People bootstrap.

- **043** after the next install: confirm Settings › Clients lists the same
  clients, `plug` reconnects without a prompt, and `paired-clients.json` is gone.
- **046** before the verifier rewrite: the owner runs five read-only status
  commands on the Mac and pastes the output (the plan lists them). All script
  behaviour checks are owner-run. The plan moves `sudo` from inside the capture
  wrapper to the wrapper itself; review that change before accepting it.
- **050**: every real run of `release.sh`, `ship.sh`, `install-local.sh`. The
  first install afterwards deletes all but the five newest install backups.
- **051** after the next install: confirm the iCloud session, pairing, and one
  tool per permission family still work (entitlements change).
- **049** after the next install: try Notes and Maps tools once.
- **052**: authorise the push and PR; add the two new check names to branch
  protection if required checks are in use.
- **054** before release: try `events_update` on a throwaway recurring event,
  and `reminders_delete` on a throwaway reminder (one plain, one repeating).

### Decisions made on the owner's behalf (2026-10-12)

- **Apple ID password stays saved**, always, in the this-device-only Keychain,
  with no opt-in checkbox. It is what prevents a daily sign-in and 2FA loop; the
  sign-in sheet discloses it and Sign Out deletes it. 045 makes Sign Out
  reachable after a failed sign-in, and 053 marks the older "never persisted"
  design docs as superseded.
- **Write verbs: yes, minimal** (054): `reminders_update`, `events_update`,
  `location_place_delete`, and `reminders_delete` (added 2026-10-12 at the
  owner's request; one reminder per call, by identifier).
- **Activity log: no.** **Confirmation-prompt system: no**; correct annotations
  (039) and the ring cooldown (040) cover the need.
- **Images**: cap size (038) and default to JPEG (049); PNG stays selectable.
- **Reversed on 2026-10-12, both kept**: the `photos_search` place-name lookup
  (049 had deleted it) and the `imcp-server --pair <code>` flag (043 had removed
  it). Simplification must not remove working behaviour.
- **About-box links** point at `cyberpapiii/iMCP` (048). That repository has
  been public since 2026-11-09, so the links work for everyone.

### Reconciliation of the third audit's open findings

| Finding | State |
|---|---|
| Sandbox-only entitlements left in place | Planned: 051 (cleanup only; restoring the sandbox is not planned) |
| Server not authenticated to the CLI | Partly planned: 043 withholds the pairing code on the Bonjour path. The wire-format change is still open |
| Trust store in `UserDefaults` | Fixed earlier (Keychain). The Debug plain-file store is planned in 043 |
| CLI terminates instead of falling back on a stale endpoint file | Planned: 044 |
| Approval dialog: unsanitised name, failed signature looks normal | Planned: 043 |
| Permission probes fan out with no cache | Partly planned: 048 |
| `CLI/main.swift` is 822 lines of top-level code | Fixed (split into `StdioProxy.swift`, `MCPService.swift`, `CLIBootstrap.swift`); 044 adds `StdioProxy` to the test target |
| Message framing implemented twice | Planned: 044 step 5 |
| Pre-authenticated auto-approve untested | 037 deletes the tautological test; real test deferred to 043 |
| `ClaudeDesktopConfigTests.swift` junk drawer | Still open, not planned |
| Dead code in `Capture.swift` | Fixed |
| CI: DerivedData cache key | Fixed |
| CI: Weather never compiled | Planned: 052 (Release build job) |
| `release.sh` has no `-R` | Planned: 050 (the existing guard exits only a subshell) |
| Two script directories | Fixed (`script/` removed); `shellcheck` gate planned in 052 |
| Window controllers owned by the menu view | Fixed |
| `@State` default runs `FullDiskAccess.isGranted` | Planned: 048 |
| Auth frame extension inferred from a value range | Still open; latent, needs a protocol version bump |

### Findings considered and rejected (fourth audit)

- **Service toggles in `UserDefaults`**: accepted. Any process that can write
  them already runs as the owner.
- **Splitting `Location.swift`, `ICloudAuthFlowTests.swift`, `AppModelTests.swift`**:
  size alone is not a defect; splitting adds churn and pbxproj edits.
- **Removing the pairing and iCloud credential migration code**: risk of losing
  the owner's pairing or session outweighs the lines saved.
- **Empty `ListPrompts` / `ListResources` handlers**: clients may call them.
- **Activity log; confirmation-prompt system; per-tool switches; `contacts_list`;
  Notes create**: declined or deferred by the owner.
- **`ship.sh --dry-run`**: does not fall out of the 050 changes.
- **System notification on first pairing**: would add a notification permission
  prompt; hook point recorded in 043.
- **Deleting "Clear Key"** (Find My People): refuted; Purge also deletes the
  identity secret and friend history. 046 keeps it behind a confirmation.
- **Deleting `reconciledGeneration`**: refuted; it is the only test coverage of
  the sampler ordering rule.
- **Deduplicating geocode coordinates in `location_visits`**: already done.
- **`item as! SecKey`**: standard CoreFoundation idiom, not a defect.
- **SIGTERM skips the cookie flush**: true, not fixed; scripts kill the app with
  `pkill`. Recorded in 045.
- **Silent enum fallbacks in CallHistory `direction`, BrowserHistory `browser`,
  Calendar `status`/`availability`, Reminders `priority`**: recorded in 038's
  maintenance notes, not fixed.

### Not audited or not verified

- No build, test, script, or benchmark was run during this audit.
- "Only HTTP 401 means wrong password" (045) rests on the repo's own tests, not
  on live Apple behaviour.
- The anchored patterns in 046's verifier rewrite are unverified until the
  owner supplies real command output.
- Whether Xcode still synthesises `user-selected.read-write` after 051.

