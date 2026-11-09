# AGENTS.md

iMCP is a macOS menu-bar app plus a bundled `imcp-server` CLI. The app in
`App/` owns the UI, service toggles, and macOS permission access. The CLI in
`CLI/` is an MCP stdio server that proxies requests to the running app. It
prefers a direct `127.0.0.1` loopback connection on the port the app
publishes to a listener-endpoint file, and falls back to Bonjour discovery
(`_mcp._tcp`, `local.`). That order matters. macOS gates Bonjour resolution
behind the Local Network privacy permission, and a background daemon like the
CLI never gets prompted for it. The CLI is inert unless the app is running and
at least one service is enabled.

## Commands

```console
# Build the app and bundled CLI into the tree Scripts/test.sh shares; the
# installed app is left alone
Scripts/install-local.sh build

# Run both test suites (CI runs the same script). It pauses the installed
# app's watchdog and imcp-server processes, stops the app, and restores them
# afterwards; the app suite cannot launch otherwise. A test that runs past
# one minute fails as hung, and the run goes on with the next test.
Scripts/test.sh

# Narrow the run: --app-only, --cli-only, --no-build, or one app test class
Scripts/test.sh --only iMCPTests/VisitInferenceTests

# Report why a permission or sign-in prompt came back
Scripts/doctor.sh

# Format Swift sources before committing, then run the CI format gate
Scripts/lint.sh --fix

# CI format gate alone; --scripts runs the CI shellcheck/Python/Node checks
Scripts/lint.sh

# Measure installed app latency, startup, memory, loaded CPU, and loopback throughput
Scripts/measure-full-stack-performance.sh
```

Do not run the `iMCP` scheme's test action through `xcodebuild` yourself. The
always-on watchdog relaunches `/Applications/iMCP.app`, and a running installed
app stops the test bundle from launching. Never `launchctl bootout` the
watchdog to work around it; `Scripts/test.sh` pauses and resumes it.

The full-stack benchmark measures `/Applications/iMCP.app`, not an Xcode build
product. Its `imcp-server` sessions need an approved client key; set
`IMCP_KEY_FILE` to one, or the run stops at the first `initialize`. It
terminates and relaunches the installed app several times, so every MCP client
connected during a run loses its session; do not run it while a client is in
use. Its own MCP requests return no user data. It restores the initial running
state and emits one JSON object. Compare code candidates against a freshly
reinstalled control because enabled services and restored iCloud state can
materially change payload size and resident memory between runs.

CI enforces `Scripts/lint.sh` (`swift format lint --strict --recursive .`).
Run `Scripts/lint.sh --fix` before finishing code changes. The `.swift-format`
configuration uses 4-space indentation, 120-column lines, and disables
`AlwaysUseLowerCamelCase`.

CI (`.github/workflows/ci.yml`) builds and tests Debug through
`Scripts/test.sh` with the pinned Xcode (`XCODE_VERSION`, the one place the
version is written) on macOS 26, compiles Release once, and runs
`Scripts/lint.sh --scripts` (`shellcheck`, `python3 -m py_compile`,
`node --check`, and ship.sh's merge gate against canned results). Those run
on every pull request and again on the push that merges it; only the run on
`main` saves build caches, because a cache saved from a pull request can be
restored by that pull request alone. Twice a week, and when the workflow is
run by hand, it runs the build and tests on GitHub's Xcode 27 preview image
instead; that job is not part of a pull request's checks, and a failure
fails the scheduled run. Its name ends in ` (experimental)`, which is how
`Scripts/ship.sh` would know it may merge without it if it ever ran there.
Every macOS job prepares Xcode through `.github/actions/prepare-xcode`,
which takes the Xcode version as an input and also writes the CI
entitlements from the configuration's own file and the `SIGNING_OVERRIDES`
that sign with them.

The Xcode project treats warnings as errors. SourceKit lies, though. It
reports spurious warnings such as "Cannot find type '____' in scope" or
"No such module '___'". Follow
`.cursor/rules/ignore-sourcekit-warnings.mdc`, and do not install new Swift
packages to chase those editor-only warnings.

## Key paths

- Planning and knowledge records: see `## Records` below.
- `App/` is filed by feature: a feature folder holds its model, its logic,
  and its window. It is a synchronized folder, so moving or adding a file
  needs no `project.pbxproj` edit. Dependencies point down: the root depends
  on everything and nothing depends on it; screens (`Menu/`, `Settings/`) sit
  on `Server/`, `Status/`, `Pairing/`, and `Location/`; features sit on
  `Tools/`, `UI/`, and `Support/`; `Support/` depends on nothing in `App/`.
- `App/App.swift`, `App/AppEnvironment.swift`, `App/ServiceRegistry.swift` -
  the composition root. `HostMode` decides once whether this process is the
  app or the test host, and the test host gets an inert dependency set (no
  listener, no services, no Keychain, no iCloud restore, no focus) instead of
  `isRunningTests` checks in each type. `HostDependencies` hands the service
  entries to both `ServerController` and `ServerNetworkManager`.
  `AppEnvironment` makes every window presenter with the host's activation
  and hands their `show` closures down; `ServiceRegistry` is the table of
  every service's entry, the only place the service types are named
  together.
- `App/CommandLine/` - the launch arguments that do one job and exit
  (`--always-on`, `--icloud-status`, `--doctor-facts`).
  `EarlyExitCommands.runIfRequested()` is the first thing `App.init` does,
  before any of the app's objects exist; add a new flag there.
- `App/Server/ServerNetworkManager.swift` - the listener and every
  connection's lifecycle: auth-preamble verification, the admission decision
  (`ConnectionSession.swift` holds the trust rules and the phase deadlines;
  the setup deadline runs on an injected `WallClock`), pairing through
  `PairedClientStore`, tool gating, and removal as soon as the
  transport reports a close. `MCPConnectionManager` reports to it through
  `ConnectionHooks`. `NetworkDiscoveryManager` owns the listener: it starts,
  stops, and replaces it after a failure or an outside cancel, and reports
  one state (`stopped`, `starting`, `listening`, `failed`) that the endpoint
  file and the Server status row follow.
- `App/Server/ServerController.swift` - the master switch and service
  enablement, applied in write order to the listener, the tool gate, and each
  service's `enablementDidChange`, whoever writes them. Each service's on/off
  switch lives in `UserDefaults` and is read through
  `ServiceSwitch.isEnabled` (`ServiceSwitch.swift`); do not wrap it in a
  cached `Binding` (see
  `docs/solutions/ui-bugs/service-toggle-stale-redraw.md`).
- `App/Tools/` - the service contract and what every tool is made of.
  `Service.swift` is the protocol; `ServiceEntry.swift` is one service's
  name, switch key, and ID. `ToolCatalog.swift` builds, lists, and calls the
  tools. `ToolArgument.swift` makes each tool argument's JSON Schema and its
  parser from one value; declare a new argument as one of its kinds (or a
  `ToolArgument` with an explicit schema), never as a hand-written schema
  plus a separate read, so tools/list cannot drift from what is enforced.
  A wrong-typed value throws `ToolInputError` naming the key; `ToolErrors.swift`
  decides which error text reaches a client. `ServicePermission.swift` is what a
  service needs from macOS: its badge and Settings wording, its tool error,
  its toggle policy, and whether its tools run `activate()` first.
  `activate()` never opens System Settings; `App/Status/GuidanceRouter.swift`
  does. `ImageEncoding.swift` is the resizing and the PNG and JPEG encoding the
  image tools share.
- `App/Services/` - one file per MCP service, with folders for the services
  that share code: `EventKit/` (Calendar, Reminders), `Capture/`,
  `Contacts/`, `Notifications/`, and `SQLite/` (the bookmarked database
  reader and the Full Disk Access probe the SQLite services share).
- `App/Location/` - the Location service and everything it owns.
  `LocationService.swift` holds only the tool declarations and thin handlers;
  what they and the Location window share lives beside it: `LocationTrack`
  (whose track, which device), `LocationHealth` (is recording healthy, and
  the `iCloud` wire names), `LocationPolicy` (every threshold and default,
  the sample interval included; it reads nothing else), `LocationVocabulary`
  (the stored provider, subject-key, and subject-kind values),
  `PointDescription` (place, address, and venue wording),
  `LocationPersonResolver` (a person query across both
  providers), and `LocationReports` (the wire DTOs; field order is key
  order). `LocationDataLifecycle` is everything Settings does to stored
  Location data; `LocationHistoryStore.changes()` announces each write, and
  the store owns the place-name rule (`NamedPlace.name(from:)`) the tools
  and the window both go through.
  `LocationEnvironment` makes Location's long-lived parts once (the iCloud
  session included), hands the sampler and the Find My People gate each
  other's hooks; `LocationWindowModel.live()` builds the window's model from
  those parts, so the Location core never names its window. `LocationService`
  and `LocationWindowModel` take every dependency, so a test passes its own.
  `UI/` is the Location window (`LocationWindowModel`, the map, the stop
  sidebar, and `PlaceSheets`) and its Settings sections.
- `App/Location/ICloud/` - the Find My client, iCloud sign-in, and the
  session. `ICloudAuthClient.recover(_:)` is the one recovery ladder (cached
  endpoints, cookie validation, Find My probe, Find My's own password page,
  password sign-in) and returns one outcome; `ICloudSession.swift` is the one
  state machine that lands it. The session owns every renewal task; the
  sampler only follows its published client changes. `ICloudStatus.swift`
  turns the session's state into the words every screen shows, with
  `ICloudStatus.needsOwner` the one answer to whether the iCloud row waits
  for the owner, and `ICloudSession.problem` the one text for what went
  wrong (the menu, Settings, the Location window, and the tools all show it);
  every tool error for a missing or unrenewed session is
  `ICloudStatus.toolError`. Every unattended password goes out through
  `armPasswordGuard`, which also stamps the stored record's
  `lastUnattendedPasswordAt` (the 5-minute renewal throttle, which a
  relaunch keeps); each password rung puts the menu in "Signing in…" as it
  begins. The stored record has one writer, `ICloudCredentialStorage.update`
  (read and save in one Keychain call), and the live cookie jar is never
  written while a sign-in is in progress.
- `App/Location/FindMyPeople/` - the Find My People readiness gate,
  bootstrap, and local-storage provider (see the Find My People rule below).
  The provider reads the decrypted database only through
  `ReadOnlySQLite(deserializing:)`, which keeps it in memory.
- `Shared/` - code compiled into the app, the CLI, and the CLI tests.
  `WireContract.swift` holds what both sides must agree on (Bonjour service
  type and name, app bundle id, Application Support directory, loopback
  `NWParameters`, the 1 MiB client message limit, pairing-code rules, and
  `HandshakeDeadline`, the CLI's and the app's handshake waits in the one
  order they work in);
  `AuthPreamble.swift` and `MessageFrameScanner.swift` are the wire format;
  `ListenerEndpointFile.swift` and `AppSigningTrust.swift` are the loopback
  handoff and whom it trusts (`ListenerEndpointFile.inspect` takes the trust
  check as a required argument); `KeychainItem.swift` (the item and
  `KeychainItemCalls`, its raw calls, which tests replace),
  `DeadlinedValue.swift`, `Latch.swift`, `OnceFlag.swift`, and
  `NWConnection+Async.swift` (a cancellable read, a send that returns once
  the bytes are taken, and the one "start and wait until ready" for a
  connection, which the app transport and the CLI proxy both use) are the
  shared keychain, async, and socket primitives. It is a
  synchronized folder of all three targets, so a new file here joins every
  one of them with no `project.pbxproj` edit. Put only code both sides need
  here.
- `App/Pairing/` - app-only client pairing: the pairing-code issuer,
  paired-client storage, and the Connect a Client window. `PairedClientStore`
  is the only writer; `pair` returns once the client is saved, and
  reports each pairing on `pairingOutcomes` after the list is reloaded.
  `PairedClientStorage` reads and writes the list through a
  `KeychainItemQueue`, so a Keychain prompt never stalls the menu or a
  connection's auth; a write reads the definitive list first and fails,
  without landing later, when it has not finished within its deadline. The
  auth path's lookup waits only `HandshakeDeadline.pairedLookup`, which with
  the CLI's wait for its auth answer stays under the setup deadline, so a
  list that does not answer leads to the approval prompt instead of a closed
  session.
  `PairingCodeIssuer` publishes when the code on show is redeemed or guessed
  away, and each `PairingOutcome` says whether a code or the prompt made it,
  so the Connect window says "Paired with" only for its own code.
  `Approval/` is the approval prompt: the contract the server asks through
  (`ApprovalAnswer`, `ApprovalPrompt`, `ConnectionApprovalRequest`) and
  `ConnectionApprovalPresenter` (queue, timeout on an injected `WallClock`,
  and window; every request it is handed is answered once).
- `CLI/` - the `imcp-server` target. `main.swift` handles arguments and
  startup and builds the one logger that it passes
  to `MCPService.swift`, which finds and connects to the
  app, and `StdioProxy.swift`, the stdio proxy. No other file reads a global.
  Alongside them sit `BonjourEndpointSelection.swift`, `CLIBootstrap.swift`
  (timeouts, notices, recovery rules), `ClientKeyStore.swift`, and
  `StdinFrameScanner.swift` (splits stdin into whole JSON-RPC messages). The
  CLI's Keychain key stays in the file keychain (`KeychainItem`
  `.fileOnly`); do not move it. `ClientKeyStore` makes a new key only where
  none exists: a Keychain it could not read fails instead, because a new
  key there would turn a paired client into an unknown one. `StdioProxy`
  reads the key before it connects, so a Keychain prompt delays the
  connection instead of letting the client's initialize reach the app ahead
  of the signed auth answer.
- `AlwaysOnHelper/` - the `iMCPAlwaysOn` watchdog target. It relaunches the
  installed app when it exits, which is why tests go through
  `Scripts/test.sh`.
- `Packages/SRP/` - local Swift package with the SRP math for iCloud sign-in.
- `iMCPTests/` (app, scheme `iMCP`) and `CLITests/` (CLI, scheme
  `imcp-serverTests`) - unit tests, one file per subject. Both are
  synchronized folders, so a new test file runs with no project edit. The CLI
  test bundle has no host: it compiles `CLI/` (except `main.swift`) and
  `Shared/` itself. Shared test doubles live in `iMCPTests/Support/`
  (`AsyncGate`, `Counter`, `TestClock`, temporary defaults and directories,
  `InMemoryKeychainItem` (the one Keychain double, with the failure knobs
  tests need, and the paired-client, iCloud, and Find My People storages
  built on it, and `waitForSaves`), `CountLatch` (a test wait that fails
  after 5 s instead of hanging), `waitUntil` (the one poll, for state
  nothing announces, such as AppKit layout), `ScriptedTransport`, `LoopbackClient.swift` (a
  real loopback client of a `ServerNetworkManager`, `ApprovalPromptRecorder`,
  and `makeServerNetworkManager`), `LoopbackSocketPair` (every test socket,
  on one listener for the run; see
  `docs/solutions/integrations/loopback-connect-port-collision.md`),
  iCloud credential, Location, and
  Find My People fixtures); use them rather
  than writing another. `NWListener+StartUntilReady.swift` is compiled into
  `imcp-serverTests` too (the project lists it), so it imports nothing from
  either product. A test `NWListener` does not advertise Bonjour: the test
  host fails any type the app does not declare
  (`docs/solutions/integrations/test-listener-bonjour-noauth.md`). Tests
  that move time pass `TestClock.wallClock` and then call the owner's
  `settle()` instead of sleeping; `TestClock`'s doc comment lists both.
- `Scripts/` - `release.sh` (release automation), `install-local.sh`
  (re-signs and installs a local Debug build with a stable identity; pass
  `build` to compile only, or `run`, `debug`, `logs`, or `telemetry` to
  relaunch afterward; a relaunch also restarts the watchdog, waits
  for the new app's listener, and runs the gitignored
  `Scripts/post-install.local.sh` if present), `verify-app-signing.sh`
  (asserts signature/entitlements; the required ones are every key
  `App/App.Debug.entitlements` turns on), `test.sh` (runs both suites with the
  installed app stopped, then restores it), `lint.sh` (format and script
  checks), and `doctor.sh` (read-only report on signing, keychain, and process
  state; it reads the build's Keychain services, bundle id, and paths from
  `iMCP --doctor-facts`, and `DoctorFactsCommandLineTests` fails when the app
  names a Keychain service the facts leave out).
- `Scripts/lib/imcp.sh` - sourced by the shell scripts. It is the only place
  that knows the install path (`IMCP_INSTALL_APP`), the shared build tree
  (`.build/DerivedData`, `IMCP_DERIVED_DATA_PATH`) and the Debug
  `xcodebuild` flags both builds use (`IMCP_XCODEBUILD_DEBUG`), which processes belong to
  the install (by exact executable path), and how to pause, stop, relaunch,
  and wait for the app. Put new process handling there. It never calls
  `launchctl`.
- `Scripts/lib/ci-checks.sh` - ship.sh's merge gate: every CI check must
  pass except one whose name ends in ` (experimental)`, which ci.yml appends
  to each `experimental` matrix entry. `Scripts/lib/ci-checks-test.sh`
  checks it offline.
- Make `Scripts/install-local.sh run` the final local-development command
  after tests. It removes its own build product and every other iMCP app
  bundle (Xcode or plain `xcodebuild` products) from Launch Services, and then
  registers only `/Applications/iMCP.app`. It keeps its own product in
  `.build/DerivedData`, so `Scripts/test.sh --no-build` still works after an
  install.
- Find My People is an expert preview. Its routine provider may only read the
  Apple database and WAL; it must never write decrypted SQLite pages or key
  material to disk. Bootstrap is human-gated: agents and app code must not
  enter Recovery, change SIP/AMFI/boot policy, reboot, attach LLDB, or enter a
  password. Safe automation is limited to status, dry-run, fixture, format,
  build, signing, and metadata-only privacy checks. Follow
  `docs/find-my-people-setup.md` and preserve its explicit user-run gates.
- `Scripts/find-my-people-bootstrap.sh` orchestrates only explicit user-run
  bootstrap checkpoints; `verify-find-my-people-security.sh` fails closed on
  incomplete posture evidence; `observe-find-my-people.sh` must remain blind
  to names, coordinates, identifiers, keys, SQL, and absolute user paths.
  `find_my_people_artifacts.py` owns the scripts' side of the artifact
  contract (formats, magic, file names, JSON keys) and the private-file reader
  and publisher; the LLDB capture and the root verifier both use it.
  `FindMyPeopleArtifactScriptContractTests` fails when it, or the observer's
  database paths, drift from the Swift side.
- `App/Status/` - the app's status for the menu-bar icon, the menu, and
  Settings: each row's words, level, and where a click on it leads
  (`AppStatus.swift`, `AppStatusModel.swift`), and `GuidanceRouter`, which
  takes the owner to where a missing permission is granted.
  `AppStatus.serviceAccess` is the one answer to whether each service that
  is on can reach its data; the menu badge, the Settings rows, and the Full
  Disk Access row read it, and every grant goes through
  `AppStatusModel.requestAccess(for:)`.
- `App/Settings/` - the Settings window: a sidebar of pages (iMCP's state on
  top, then General, Permissions, Clients, Location, About) with search and
  Back and Forward. It is a `Window` scene, not a `Settings` scene, because a
  Settings window gets no toolbar. `SettingsModels.swift` holds its pure
  models (the pages, their search words, the history), and `LoginItems.swift`
  the Launch at Login and always-on switches.
- `App/Menu/` - the menu bar extra: the menu, its icon, and the service
  toggles.
- `App/UI/` - what has no feature: `DesignTokens.swift` (spacing, type,
  motion, and the shared glass and material helpers),
  `SingleWindowPresenter.swift` (how a window of this menu bar app comes to
  the front: activate, then order front; use it for any new window),
  `ServicePresentation.swift` (each service's icon and color, keyed by ID),
  and `StatusSummary.swift` (the status row vocabulary).
- `App/Support/` - Foundation, AppKit, Logger, and Bundle extensions,
  `NamedCases`, `AppLinks` (the web pages the app opens), `WallClock`
  (`Clock.swift`: the time of day and a sleep until a date, injected wherever
  a test moves time), `PreferenceKey` (persisted key names, each with its
  default; the names must never change), `KeychainItemQueue` (one serial
  queue per Keychain item for every call to it, off the Swift concurrency
  pool: deadlined reads that never start a second read behind a blocked
  one, an awaiting `perform`, and a deadlined `run`; reads and `run` wait
  `KeychainItemQueue.promptDeadline` unless a caller has reason to wait
  less; it decides that only
  `missing` is absence and drops a kept read after every write, and every
  app secret is read and written through it; each storage's `production`
  is the one instance per item), `AlwaysOnService` (the
  always-on agent's `SMAppService`), `ReadOnlySQLite` (the read-only SQLite
  reader behind the SQLite services and Find My People's local database),
  and `ReverseGeocoder` (the one
  reverse-geocoding call and the one placemark wording that Maps, Photos, and
  Location share; the address strings are wire output).

## Records

Each planning tool writes to its own default home. Keep those homes, so the
tools find their own history, and never delete a record as cleanup; git shows
what shipped.

| Path | Written by | What it is | Lifecycle |
| --- | --- | --- | --- |
| `docs/solutions/` | compound-engineering `ce-compound` | One verified lesson per file, with frontmatter (`module`, `tags`, `problem_type`). The knowledge store planning and review read first. | Update in place. Prune only through `ce-compound-refresh`. |
| `docs/plans/` | compound-engineering `ce-plan`, `ce-brainstorm` | Dated decision record for a feature or fix. | Never edited after execution starts; no status field. Keep. |
| `docs/ideation/` | compound-engineering `ce-ideate` | Ranked idea lists. | Keep. |
| `plans/` | `/improve` | Numbered audit plans, with `plans/README.md` as the status index and rejected-findings list. | Update the index row (`DONE`, `REJECTED`); keep the plan files. `/improve reconcile` maintains it. |
| `.audit/`, `.context/` | pstack `show-me-your-work`, compound-engineering run state | Decision trails and tool state for one run. | Gitignored and local. Commit a trail only when a reviewer needs it. |

`Scripts/ship.sh` refuses a change that deletes files under `plans/`,
`docs/plans/`, or `docs/ideation/` unless it is given `--allow-record-deletes`.

## Finishing a change

Every chunk of work ends the same way, without being asked:

1. Update what the change made stale: `README.md`, this file, and any
   `docs/solutions/` entry. Delete code, scripts, docs, and tests the change
   left dead rather than marking them deprecated. Records (above) are the
   exception: never delete them as cleanup.
2. Record a non-obvious lesson (a root cause, a trap, a tool quirk) as a
   `docs/solutions/` entry.
3. `git add` new files, then run
   `Scripts/ship.sh -m "<commit message>" -b "<PR body>"`. It formats, lints,
   and builds locally, then commits, pushes, opens a PR, waits for every CI
   check (CI runs both test suites), merges only when each one passed (an
   experimental check that did not pass is printed as a warning and does not
   block), updates exact `main`, installs and
   relaunches the verified app, and removes the merged branch, the worktree,
   and every other local branch whose PR already merged. If CI fails, fix it
   and re-run the same command; it reuses the open PR. Pass `--local-tests`
   to run `Scripts/test.sh` first when CI alone is not enough. Do not repeat
   these steps by hand.
4. Use `--release <version>` only for a notarized public release; it requires
   the existing `KEYCHAIN_PROFILE` credential.
