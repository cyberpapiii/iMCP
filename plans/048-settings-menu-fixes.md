# Plan 048: Settings and the menu tell the truth, with less code

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- App/Views/ App/Controllers/PairedClientStore.swift App/Controllers/PairedClientStorage.swift App/Controllers/ServiceRegistry.swift App/Controllers/ServerController.swift App/Controllers/ServerNetworkManager.swift App/Models/AppStatus.swift iMCPTests/PairedClientStoreTests.swift iMCPTests/AppModelTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding. Line
> numbers will have moved; that alone is fine. If the *code* in an excerpt no
> longer exists or says something different, treat it as a STOP condition for
> that step (see "STOP conditions" for which steps may be skipped).

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW (UI and view-model only; no tool, protocol, or storage-format change)
- **Depends on**: `plans/037-isolate-tests-from-real-state.md`; and PR #61
  (`feat/menu-bar-resilience`, commits `887575d` + `8165d29`) merged into `main`
- **Category**: bug, tech-debt
- **Planned at**: commit `8165d29` (branch `feat/menu-bar-resilience`), 2026-10-12

## Why this matters

The Settings window and the menu-bar menu disagree with each other and with
macOS in several small ways, and each one makes a user distrust the app:
the Launch at Login toggle and its red "Approval needed" text stay stale after
the user approves the login item in System Settings; the menu says Full Disk
Access is "Granted" while the Permissions tab says "Not granted"; a Keychain
read that fails shows "No paired clients"; "Report an Issue" files against the
upstream project this fork never pushes to; Sign Out is one click and costs a
password plus a 2FA code to undo; the service toggles have no VoiceOver label.

The same views also do work in the wrong place: a Keychain read inside
`body`, file and launchd probes inside `@State` default values (run on every
struct init), a 1 Hz timer that invalidates a window forever.

Every fix below is done by removing or merging code, not by adding a layer.
The expected result is a net reduction of roughly 80 source lines.

## Current state

All line numbers are at commit `8165d29`. Paths are relative to the repo root
`~/Documents/GitHub/iMCP`.

### Repo facts you need

- macOS menu-bar MCP server. App target sources live in `App/` (a synchronized
  Xcode group: adding, removing, or renaming a file there needs **no**
  `project.pbxproj` edit). App tests live in `iMCPTests/`, which is **not**
  synchronized: a new test file needs four hand-made `project.pbxproj` entries.
  This plan therefore adds tests only to existing test files.
- Warnings are errors. Deployment target macOS 15.1. Local Xcode is 27 beta,
  CI is Xcode 26.0.
- Every member of a SwiftUI `View` struct is `@MainActor`-isolated, not only
  `body`. A `Task { ... }` created inside a `View` method inherits the main
  actor.
- This repository is a fork. `origin` = `cyberpapiii/iMCP` is the only
  writable remote. `upstream` = `mattt/iMCP` must never receive pushes or PRs.

### Files and their roles

- `App/Controllers/PairedClientStore.swift` (55 lines) — `@MainActor
  ObservableObject` wrapper the views observe.
- `App/Controllers/PairedClientStorage.swift` (285 lines) — the Keychain (or,
  in Debug, secret-file) store behind it. Security-sensitive; this plan
  changes exactly one method in it.
- `App/Controllers/ServiceRegistry.swift` (323 lines) — `ServiceConfig`,
  `ServiceDescriptor`, the list of services.
- `App/Controllers/ServerController.swift` (339 lines) — the app's one
  controller; owns the configs and the paired-client store.
- `App/Controllers/ServerNetworkManager.swift` — the server; four lines in it
  re-derive a service ID.
- `App/Models/AppStatus.swift` — pure functions that produce the menu's
  status lines (`ClientsStatus`, `FullDiskAccessStatus`).
- `App/Views/ContentView.swift` (330 lines) — the menu-bar menu.
- `App/Views/SettingsView.swift` (893 lines) — the three Settings tabs.
- `App/Views/ServiceToggleView.swift` (126 lines) — one service row in the menu.
- `App/Views/ConnectClientWindow.swift` (150 lines) — the "Connect a Client" window.
- `App/Views/ConnectionApprovalView.swift` (209 lines) — the approval dialog.
- `App/Views/ICloudSignInWindow.swift` (190 lines) — the iCloud sign-in window.
- `App/Views/LocationWindow.swift` — only its day-navigation header (two buttons).

### Excerpts

**A. Keychain read in `body`, no cache, failure looks like "empty".**

`App/Controllers/PairedClientStore.swift:9-11, 19-23, 36-38`:

```swift
    /// A change ticker, not the source of truth. Every read goes through
    /// `storage`. This counter exists only to give SwiftUI something to observe.
    @Published private var revision = 0
    ...
        ) { [weak self] _ in
            Task { @MainActor in
                self?.revision += 1
            }
        }
    ...
    func all() -> [PairedClient] {
        storage.all().sorted { $0.addedAt > $1.addedAt }
    }
```

`App/Controllers/PairedClientStorage.swift:104-113` (a failed read returns `[]`):

```swift
    func all() -> [PairedClient] {
        withLock {
            switch unlockedClients() {
            case .available(let clients):
                return clients
            case .unavailable:
                return []
            }
        }
    }
```

Called from two `body` implementations:
`App/Views/ContentView.swift:122`
`summary: ClientsStatus.summary(pairedCount: pairedClients.all().count),`
and `App/Views/SettingsView.swift:508`
`let pairedClients = pairedClientStore.all()`.

`App/Models/AppStatus.swift:105-116`:

```swift
enum ClientsStatus {
    static func summary(pairedCount: Int) -> StatusSummary {
        let detail: String
        switch pairedCount {
        case 0: detail = "No paired clients · each connection asks for approval"
        case 1: detail = "1 paired client"
        default: detail = "\(pairedCount) paired clients"
        }
        return StatusSummary(level: .ok, title: "Clients", detail: detail)
    }
}
```

`iMCPTests/PairedClientStoreTests.swift` calls `store.all()` (the wrapper) on
lines 37, 61, 62, 73, 82, 106, 123 and `storage.all()` (the storage) on lines
265, 290, 303. Every wrapper call is made **synchronously** right after a
mutation, so the cache must be reloaded synchronously by the mutators, not
only from the notification.

**B. Service identity derived in six places, matched by display name.**

`App/Controllers/ServiceRegistry.swift:26-34, 80-108`:

```swift
struct ServiceConfig: Identifiable {
    let id: String
    let name: String
    let iconName: String
    let color: Color
    let service: any Service
    let permissionGuidance: ServicePermissionGuidance?
    private let readEnabled: () -> Bool
    private let writeEnabled: (Bool) -> Void
    ...
    init(
        name: String,
        iconName: String,
        color: Color,
        service: any Service,
        isEnabled: @escaping () -> Bool,
        setEnabled: @escaping (Bool) -> Void,
        permissionGuidance: ServicePermissionGuidance? = nil
    ) {
        self.id = String(describing: type(of: service))
        self.name = name
        ...
    }
}

struct ServiceDescriptor {
    let name: String
    let iconName: String
    let color: Color
    let service: any Service
    let enabledKey: String
    let defaultEnabled: Bool
    let permissionGuidance: ServicePermissionGuidance?
}
```

`ServiceRegistry.swift:294-309` copies five descriptor fields into a config.
The same `String(describing: type(of: ...))` appears at
`App/Controllers/ServerNetworkManager.swift:701, 719, 760, 789`.
`App/Views/ContentView.swift:189` finds Location by display name:
`serviceConfigs.contains { $0.name == "Location" && $0.isEnabled }`.
`App/Views/SettingsView.swift:594` repeats the storage key literal:
`@AppStorage("locationEnabled") private var locationEnabled = true`
(the descriptor's copy is `ServiceRegistry.swift:174`).

`App/Controllers/ServerController.swift:5, 38-46, 96-102`:

```swift
import struct Foundation.Date
...
    private lazy var serviceConfigs: [ServiceConfig] = {
        ServiceRegistry.configureServices { descriptor in
            enabledAccessors(for: descriptor)
        }
    }()

    var computedServiceConfigs: [ServiceConfig] {
        serviceConfigs
    }
...
    func showICloudSignInWindow() {
        ICloudSignInPresenter.show()
    }

    func showLocationWindow() {
        LocationWindowPresenter.show()
    }
```

`computedServiceConfigs` is read at `ServerController.swift:78`,
`ContentView.swift:18`, `SettingsView.swift:66, 70`. `showICloudSignInWindow`
is called only at `ContentView.swift:116`; `showLocationWindow` only at
`ContentView.swift:146`.

**C. Two definitions of "Full Disk Access is fine", and probes in `@State` defaults.**

`App/Views/ContentView.swift:15`:
`@State private var fullDiskAccessGranted = FullDiskAccess.isGranted`
(`FullDiskAccess.isGranted`, `App/Models/FullDiskAccess.swift:23-30`, makes up
to four `open()` calls; a `@State` default value is evaluated every time the
struct is initialised, which for `ContentView` is every `App.body` pass).

`App/Views/ContentView.swift:192-209` (the menu's definition):

```swift
    /// The grant itself, or every dependent service reaching its database
    /// through a per-database bookmark, which is as good.
    private func refreshFullDiskAccess() async {
        if FullDiskAccess.isGranted {
            fullDiskAccessGranted = true
            return
        }
        for config in serviceConfigs
        where config.isEnabled
            && config.permissionGuidance?.requiresFullDiskAccess == true
        {
            if await !config.isActivated {
                fullDiskAccessGranted = false
                return
            }
        }
        fullDiskAccessGranted = true
    }
```

`App/Views/SettingsView.swift:63, 127-130` (the Permissions tab's definition):

```swift
    @State private var fullDiskAccessGranted = FullDiskAccess.isGranted
    ...
    private func refresh() {
        fullDiskAccessGranted = FullDiskAccess.isGranted
        refreshToken += 1
    }
```

`ContentView.swift:71-75` and `:133-135` are two observers of the same value:

```swift
                .onChange(of: serviceConfigs.map { $0.isEnabled }, initial: true) {
                    Task {
                        await serverController.updateServiceBindings()
                    }
                }
...
            .onChange(of: serviceConfigs.map { $0.isEnabled }, initial: true) {
                Task { await refreshFullDiskAccess() }
            }
```

**D. Login-item state read once, never refreshed.**

`App/Views/SettingsView.swift:326-328`:

```swift
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var alwaysOn = AlwaysOnService.isEnabled
    @State private var launchAtLoginError: String?
```

`SettingsView.swift:468-475` and `:487-492` (the read-back is written twice):

```swift
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if enabled && SMAppService.mainApp.status == .requiresApproval {
            launchAtLoginError =
                "Approval needed: enable iMCP under System Settings → General → Login Items."
        }
...
        alwaysOn = AlwaysOnService.isEnabled
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if enabled && AlwaysOnService.agent.status == .requiresApproval {
            launchAtLoginError =
                "Approval needed: enable iMCP under System Settings → General → Login Items."
        }
```

The exemplar for refreshing on re-activation is in the same file,
`SettingsView.swift:120-124`:

```swift
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refresh()
        }
```

**E. Three copies of "here is the server command".**
`SettingsView.swift:332-361` is a whole `Section("MCP Server")` in the General
tab (explanation, path, Copy button, "Connect a Client…" button).
`SettingsView.swift:571-576` is a "Connect a Client…" button in the Clients
tab. `ConnectClientWindow.swift:45-53` shows the same path with a Copy button.
The General section's own text says the Connect window is the better place.

**F. Dead `isEnabled` environment branches and two near-identical menu rows.**
`@Environment(\.isEnabled)` is false only under an ancestor `.disabled(true)`.
`grep -n "\.disabled(" App/Views/ContentView.swift App/App.swift` returns
nothing, and the only hit in `ServiceToggleView.swift` is line 54, which
re-applies the environment value to itself. So these are dead:
`ContentView.swift:214, 238, 250-258` and
`ServiceToggleView.swift:20, 51, 54, 59, 110-125`.

`ContentView.swift:213-260` (`MenuButton`) and `:262-306` (`StatusRow`) share
the same shell: a `Button` that runs an action, sets `isMenuPresented = false`,
uses `MenuItemButtonStyle(isHighlighted:)`, and tracks hover.

**G. A timer that never stops.** `App/Views/ConnectClientWindow.swift:36, 38, 107-112, 146-149`:

```swift
    @State private var now = Date()
    ...
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    ...
        .onReceive(timer) { date in
            now = date
            if let pairingCode, pairingCode.expiresAt <= date {
                self.pairingCode = nil
            }
        }
    ...
    private func expiryText(_ expiresAt: Date) -> String {
        let remaining = max(0, Int(expiresAt.timeIntervalSince(now)))
        return String(format: "Expires in %d:%02d", remaining / 60, remaining % 60)
    }
```

The window controller is kept alive (`isReleasedWhenClosed = false`,
`ServerController.connectClientWindowController`), so the timer fires once a
second for the life of the process after the window is first opened.

**H. One-click Sign Out.** `SettingsView.swift:174-179`:

```swift
            if session.isSignedIn {
                Button("Sign Out") {
                    Task { await session.signOut() }
                }
                .controlSize(.small)
                .glassButtonStyle()
```

and `ICloudSignInWindow.swift:172-176`:

```swift
            Spacer()
            Button("Sign Out") {
                Task { await session.signOut() }
            }
```

**I. Links.** `SettingsView.swift:433`
`URL(string: "https://github.com/mattt/iMCP")!`, `:438`
`URL(string: "https://github.com/mattt/iMCP/issues/new")!`, `:679`
`"https://github.com/dododosolutions/iMCP/blob/main/docs/find-my-people-setup.md"`.
Verified at planning time: `docs/find-my-people-setup.md` exists on
`origin/main`, and the fork `cyberpapiii/iMCP` has its issue tracker enabled.

**J. VoiceOver.** `ServiceToggleView.swift:27-55`: the toggle `Button`'s label
is `serviceIconCircle` (an SF Symbol in a circle); it has no accessibility
label, value, or toggle trait. `LocationWindow.swift:491-503`: the two day
buttons' labels are `Image(systemName: "chevron.left")` /
`"chevron.right"` with no label.

**K. Small leftovers.**
- `ConnectionApprovalView.swift:79-81` `.background(Color(NSColor.windowBackgroundColor))`,
  `.cornerRadius(12)`, `.shadow(radius: 10)` on a view hosted in an ordinary
  titled window; `:147-148` sets two `NSWindow` properties to their defaults;
  `:197-209` is the repo's only `#Preview`, with `print` handlers.
- `SettingsView.swift:649-654` and `:659-664` are the same "Cancel Setup" button twice.
- `SettingsView.swift:620` `Button("Status") { Task { await refresh() } }` —
  the Permissions tab calls the same action "Refresh" (`:105`).
- `SettingsView.swift:754, 764` `@MainActor` on methods of a `View` (already
  main-actor), and `:741` `Task { @MainActor in` inside one.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0, no output |
| One app test class | `Scripts/test.sh --only iMCPTests/<TestClass>` | all pass |
| App tests | `Scripts/test.sh --app-only` | all pass |
| All tests | `Scripts/test.sh` | all pass |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

`--only SPEC` passes `-only-testing:SPEC` and implies `--app-only`
(`Scripts/test.sh:20`), so the spec must include the target: for example
`iMCPTests/PairedClientStoreTests`.

**Never** run `xcodebuild test -scheme iMCP` directly: the always-on watchdog
relaunches the installed app and breaks the test host. **Never**
`launchctl bootout` the always-on agent. `Scripts/test.sh` handles both.

The shell is zsh: quote any glob you pass to `grep --include`.

## Scope

**In scope** (the only files you should modify):

- `App/Controllers/PairedClientStore.swift`
- `App/Controllers/PairedClientStorage.swift` — only `func all()` (lines 104-113)
- `App/Controllers/ServiceRegistry.swift`
- `App/Controllers/ServerController.swift` — only lines 5, 38-46, 78, 96-102
- `App/Controllers/ServerNetworkManager.swift` — only the four ID lines (701, 719, 760, 789)
- `App/Models/AppStatus.swift` — only `ClientsStatus`
- `App/Views/ContentView.swift`
- `App/Views/SettingsView.swift`
- `App/Views/ServiceToggleView.swift`
- `App/Views/ConnectClientWindow.swift`
- `App/Views/ConnectionApprovalView.swift` — deletions only
- `App/Views/ICloudSignInWindow.swift` — the Sign Out button and one new small view
- `App/Views/LocationWindow.swift` — only the two chevron buttons at 491-503
- `iMCPTests/PairedClientStoreTests.swift`
- `iMCPTests/AppModelTests.swift`
- `plans/README.md` — your status row only

**Out of scope** (do NOT touch, even though they look related):

- `LocationWindow.swift` beyond the two chevron buttons, and
  `LocationHistorySection` in `SettingsView.swift:774-893` — plan 047.
- Sign-in window logic (window lifetime, 2FA screen, Return-key guards) and
  the menu's Quit not flushing cookies (`ContentView.swift:154-156`) — plan 045.
- The "Clear Key" button (`SettingsView.swift:666-671`), the keychain result
  enums in `PairedClientStorage.swift:12, 273-279` — plan 046.
- The approval-window race and the unsanitised client name
  (`ConnectionApprovalView.swift:39, 152`, `ServerController.swift:139-147`),
  and the pairing-code wording about `--pair` (kept as is; owner decision
  2026-10-12).
- Raw `error.localizedDescription` shown in UI
  (`SettingsView.swift:466, 484`) — plan 042. Leave those two lines exactly as they are.
- `PairedClientStore`'s `convenience init(userDefaults:)` and anything else
  plan 037 changed about how tests build stores. Keep whatever 037 left.
- `ServiceRegistry.swift:276` `#if WEATHERKIT_AVAILABLE`. Do not change it
  (see Maintenance notes).
- `let serverLog = Logger.server` (`ServerController.swift:10`, 77 uses in five
  files) and `@AppStorage("isEnabled")` (`ServerController.swift:34`). Not
  worth the churn; leave them.
- `App/App.swift`. No edit is needed there.
- Anything under `Scripts/`, `CLI/`, `AlwaysOnHelper/`, `docs/`, `README.md`.

## Git workflow

- Start from an up-to-date `main` that contains PR #61:
  `git fetch origin && git switch main && git pull --ff-only`, then
  `git merge-base --is-ancestor 8165d29 HEAD && echo OK` must print `OK`.
- Branch: `advisor/048-settings-menu-fixes`.
- One commit per step. Conventional commits, matching `git log`, for example
  `fix: bring Settings forward from the menu; stay quiet on relaunch`.
  Suggested messages are given per step.
- Do NOT push or open a PR unless the operator instructed it. Never push to
  or open a PR against `upstream` (`mattt/iMCP`).

## Steps

Every step leaves the app building. Run the Build command after each step
even where a narrower check is also given.

### Step 0: Preconditions

1. `git merge-base --is-ancestor 8165d29 HEAD && echo OK` → prints `OK`.
   If not, STOP: PR #61 is not merged and three in-scope files would conflict.
2. Check `plans/README.md` for plan 037's row. If it is not DONE, STOP and
   report (the operator may tell you to proceed anyway; step 1's tests are the
   only part that depends on it).
3. Run the drift check from the top of this file.
4. Build → exit 0. `Scripts/test.sh --app-only` → all pass. Record the test
   count; it is your baseline.

### Step 1: `PairedClientStore` publishes a cached list; "unreadable" stops looking like "empty"

**1a. `App/Controllers/PairedClientStorage.swift`, `func all()` only.** Return
`nil` when the store cannot be read:

```swift
    /// nil when the store could not be read, which is not the same as empty.
    func all() -> [PairedClient]? {
        withLock {
            switch unlockedClients() {
            case .available(let clients):
                return clients
            case .unavailable:
                return nil
            }
        }
    }
```

Touch nothing else in this file. `contains`, `add`, `remove`, `reset` already
treat "unavailable" correctly and are the trust path.

**1b. `App/Controllers/PairedClientStore.swift`.** Replace the `revision`
ticker and `all()` with a published cache. Target shape of the changed parts
(keep `deinit`, the convenience init, and `contains` as they are):

```swift
    /// Newest first. nil when the store could not be read. A cache for the
    /// views only: `contains` still asks `storage` every time.
    @Published private(set) var clients: [PairedClient]?

    init(storage: PairedClientStorage) {
        self.storage = storage
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: PairedClientStorage.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
            }
        }
    }

    func reload() {
        clients = storage.all()?.sorted { $0.addedAt > $1.addedAt }
    }

    func add(_ client: PairedClient) {
        _ = storage.add(client)
        reload()
    }

    func remove(fingerprint: String) {
        storage.remove(fingerprint: fingerprint)
        reload()
    }

    func reset() {
        storage.reset()
        reload()
    }
```

Delete `@Published private var revision`, its doc comment, and `func all()`.
The mutators reload synchronously because the notification's `Task` hop is
asynchronous and callers (and tests) read straight after writing. The
notification covers writes made elsewhere (the network manager pairing a
client with a code).

If Swift rejects `reload()` in `init` before `observer` is assigned
("self used before all stored properties are initialized"), move the
`reload()` call to the last line of `init`.

**1c. `App/Models/AppStatus.swift`, `ClientsStatus`.** Take an optional count:

```swift
enum ClientsStatus {
    /// `pairedCount` is nil when the paired-client store could not be read.
    static func summary(pairedCount: Int?) -> StatusSummary {
        guard let pairedCount else {
            return StatusSummary(
                level: .attention,
                title: "Clients",
                detail: "Could not read paired clients · each connection asks for approval"
            )
        }
        ...existing switch and return, unchanged...
    }
}
```

**1d. Callers.**
- `ContentView.swift:122`: `pairedClients.all().count` → `pairedClients.clients?.count`.
- `SettingsView.swift:508`: replace
  `let pairedClients = pairedClientStore.all()` with
  `let pairedClients = pairedClientStore.clients ?? []`.
- `SettingsView.swift:535`: replace `Text("No paired clients")` with

  ```swift
  Text(
      pairedClientStore.clients == nil
          ? "Could not read paired clients. Unlock the Keychain, then reopen Settings."
          : "No paired clients"
  )
  ```
- On the Clients tab's `Form`, next to `.formStyle(.grouped)` (`:578`), add
  `.task { pairedClientStore.reload() }` so opening the tab retries a failed read.

**1e. Tests — `iMCPTests/PairedClientStoreTests.swift`.** Mechanical updates
for the new API:

| Line | Old | New |
|---|---|---|
| 37 | `XCTAssertEqual(store.all(), [client])` | `XCTAssertEqual(store.clients, [client])` |
| 61 | `store.all().count` | `store.clients?.count` |
| 62 | `store.all().first?.label` | `store.clients?.first?.label` |
| 73 | `store.all().count` | `store.clients?.count` |
| 82 | `XCTAssertTrue(store.all().isEmpty)` | `XCTAssertEqual(store.clients, [])` |
| 106 | `store.all().map(\.label)` | `store.clients?.map(\.label)` |
| 123 | `Set(store.all().map(\.fingerprint))` | `Set(store.clients?.map(\.fingerprint) ?? [])` |
| 265 | `XCTAssertTrue(storage.all().isEmpty)` | `XCTAssertNil(storage.all())` |
| 290 | `XCTAssertTrue(storage.all().isEmpty)` | `XCTAssertEqual(storage.all(), [])` |
| 303 | `XCTAssertTrue(storage.all().isEmpty)` | `XCTAssertNil(storage.all())` |

Rename `testAllSortsByAddedAtDescending` to `testClientsSortNewestFirst`.
Add the two tests listed under "Test plan → PairedClientStoreTests".

**1f. Tests — `iMCPTests/AppModelTests.swift`**, in `AppStatusTests`
(`final class AppStatusTests` starts at line 528), extend `testClientsRowCounts`
(line 591) with the nil case from "Test plan".

**Verify**:
- Build → exit 0.
- `grep -rn "revision" App/Controllers/PairedClientStore.swift` → no matches.
- `grep -rn "pairedClients.all()\|pairedClientStore.all()\|store.all()" App iMCPTests` → no matches.
- `Scripts/test.sh --only iMCPTests/PairedClientStoreTests --only iMCPTests/AppStatusTests` → all pass.

Commit: `fix: cache paired clients for the views; show an unreadable store as unreadable`

### Step 2: One definition of a service's identity; `ServiceConfig` holds its descriptor

**2a. `App/Controllers/ServiceRegistry.swift`.**

Add to `enum ServiceRegistry` (top of the enum):

```swift
    /// The one place a service's ID is derived. Nothing persists it; it only
    /// has to agree between the toggles and the tool gate.
    static func id(of service: any Service) -> String {
        String(describing: type(of: service))
    }

    static let locationEnabledKey = "locationEnabled"
```

In the Location descriptor (line 174) use the constant:
`enabledKey: locationEnabledKey,`.

Add to `struct ServiceDescriptor`:

```swift
    var id: String { ServiceRegistry.id(of: service) }
```

Replace `ServiceConfig`'s six copied stored properties and its eight-parameter
`init` with the descriptor itself. Target shape:

```swift
@dynamicMemberLookup
struct ServiceConfig: Identifiable {
    let descriptor: ServiceDescriptor
    private let readEnabled: () -> Bool
    private let writeEnabled: (Bool) -> Void

    var id: String { descriptor.id }

    /// `config.name`, `config.service`, and the rest read straight through.
    subscript<T>(dynamicMember keyPath: KeyPath<ServiceDescriptor, T>) -> T {
        descriptor[keyPath: keyPath]
    }

    ...isEnabled, isActivated, grantAccess(), fullDiskAccessNames(from:) stay...

    init(
        descriptor: ServiceDescriptor,
        isEnabled: @escaping () -> Bool,
        setEnabled: @escaping (Bool) -> Void
    ) {
        self.descriptor = descriptor
        self.readEnabled = isEnabled
        self.writeEnabled = setEnabled
    }
}
```

Inside `ServiceConfig`'s own methods a bare `service` or `permissionGuidance`
does not go through the subscript. Write `descriptor.service` (in
`isActivated` and `grantAccess`) and `descriptor.permissionGuidance` (in
`grantAccess`, twice). Callers outside the type (`config.name`,
`config.service.activate()`, `config.permissionGuidance?.explanation`, ...)
need no change.

Keep the existing doc comment on `isEnabled` (lines 36-40) word for word.

`configureServices` (lines 294-309) becomes:

```swift
        descriptors.map { descriptor in
            let enabled = enabled(descriptor)
            return ServiceConfig(descriptor: descriptor, isEnabled: enabled.get, setEnabled: enabled.set)
        }
```

If `@dynamicMemberLookup` fails to compile for a reason you cannot fix in one
attempt, fall back to five forwarding properties
(`var name: String { descriptor.name }`, and likewise `iconName`, `color`,
`service`, `permissionGuidance`) and continue; note it in your report.

**2b. `App/Controllers/ServerNetworkManager.swift`**, four one-line changes:

| Line | Old | New |
|---|---|---|
| 701 | `let id = String(describing: type(of: service))` | `let id = ServiceRegistry.id(of: service)` |
| 719 | `let id = String(describing: type(of: descriptor.service))` | delete the line; use `descriptor.id` in the `guard` on the next line |
| 760 | `let serviceID = String(describing: type(of: service))` | `let serviceID = ServiceRegistry.id(of: service)` |
| 789 | `String(describing: type(of: $0.service)) == id` | `$0.id == id` |

**2c. `App/Controllers/ServerController.swift`.**
- Delete line 5 (`import struct Foundation.Date`; `AppKit` already brings Foundation).
- Lines 38-46: change `private lazy var serviceConfigs` to
  `private(set) lazy var serviceConfigs` and delete the
  `computedServiceConfigs` property. Keep the doc comment above the lazy var.
- Line 78: `computedServiceConfigs.compactMap` → `serviceConfigs.compactMap`.
- Lines 96-102: delete `showICloudSignInWindow()` and `showLocationWindow()`.

**2d. Callers.**
- `ContentView.swift:17-19`: the private `serviceConfigs` computed property
  now returns `serverController.serviceConfigs`.
- `ContentView.swift:116`: `serverController.showICloudSignInWindow()` → `ICloudSignInPresenter.show()`.
- `ContentView.swift:146`: `serverController.showLocationWindow()` → `LocationWindowPresenter.show()`.
- `ContentView.swift:189`: `$0.name == "Location" && $0.isEnabled` →
  `$0.enabledKey == ServiceRegistry.locationEnabledKey && $0.isEnabled`.
- `SettingsView.swift:66, 70`: `serverController.computedServiceConfigs` → `serverController.serviceConfigs`.
- `SettingsView.swift:594`: `@AppStorage("locationEnabled")` → `@AppStorage(ServiceRegistry.locationEnabledKey)`.

**2e. Test** — add `testServiceIDsAreStable` to `ServiceFixesTests` in
`iMCPTests/AppModelTests.swift`, right after
`testEveryRegisteredServiceHasAConfig` (which ends at line 470). See "Test plan".

**Verify**:
- Build → exit 0.
- `grep -rn "String(describing: type(of" App/Controllers` → exactly two
  matches: `ServiceRegistry.swift` (the new helper) and
  `ICloudSession.swift:745` (an error type name, unrelated).
- `grep -rn "computedServiceConfigs\|showICloudSignInWindow\|showLocationWindow" App iMCPTests` → no matches.
- `grep -rn '"locationEnabled"' App` → exactly one match (the constant).
- `Scripts/test.sh --only iMCPTests/ServiceFixesTests --only iMCPTests/CallToolDispatchTests` → all pass.

Commit: `refactor: derive a service's id once; ServiceConfig holds its descriptor`

### Step 3: One answer to "is Full Disk Access satisfied?", and no probes in `@State` defaults

**3a. `App/Controllers/ServiceRegistry.swift`**, in `ServiceConfig`, next to
`fullDiskAccessNames(from:)`:

```swift
    /// The grant itself, or every enabled dependent service reaching its
    /// database through a per-database bookmark, which is as good. `granted`
    /// is a parameter so tests do not depend on this Mac's privacy settings.
    @MainActor
    static func fullDiskAccessSatisfied(
        for configs: [ServiceConfig],
        granted: Bool = FullDiskAccess.isGranted
    ) async -> Bool {
        if granted { return true }
        let dependents = configs.filter {
            $0.isEnabled && $0.permissionGuidance?.requiresFullDiskAccess == true
        }
        for config in dependents {
            if await !config.isActivated { return false }
        }
        return !dependents.isEmpty
    }
```

`@MainActor` is deliberate: it is the same isolation the loop runs in today
(`ContentView.refreshFullDiskAccess`), so no `Sendable` question arises.

**3b. `App/Views/ContentView.swift`.**
- Line 15: `@State private var fullDiskAccessGranted: Bool?` (no default probe).
- Lines 90-100: show the row only once the answer is known:

  ```swift
  if let fullDiskAccessGranted, !fullDiskAccessNames.isEmpty {
  ```
  (the body of the `if` is unchanged; `fullDiskAccessGranted` is now the
  unwrapped `Bool` inside it).
- Delete `refreshFullDiskAccess()` and its doc comment (lines 192-209).
- Delete the first observer, lines 71-75 (the `.onChange` that calls
  `updateServiceBindings`). Leave the `.transition` / `.animation` modifiers
  that follow it.
- Replace lines 130-135 (the `isMenuPresented` observer and the second
  `serviceConfigs` observer) with:

  ```swift
  .onChange(of: isMenuPresented) { _, presented in
      if presented { Task { await refreshFullDiskAccess() } }
  }
  .onChange(of: serviceConfigs.map { $0.isEnabled }, initial: true) {
      Task {
          await serverController.updateServiceBindings()
          await refreshFullDiskAccess()
      }
  }
  ```
  and add the one-line replacement method where the old one was:

  ```swift
  private func refreshFullDiskAccess() async {
      fullDiskAccessGranted = await ServiceConfig.fullDiskAccessSatisfied(for: serviceConfigs)
  }
  ```

Why merging the two observers is safe: the deleted one lived inside
`if isEnabled { ... }`, so it also fired each time the server was switched
back on. That extra firing did nothing, because
`ServerNetworkManager.updateEnabledServices` returns immediately when the ID
set is unchanged (`guard enabledServiceIDs != ids else { return }`), and the
service toggles cannot be clicked while they are hidden.

**3c. `App/Views/SettingsView.swift`, `PermissionsSettingsView`.**
- Line 63: `@State private var fullDiskAccessGranted: Bool?`.
- Line 88: `PermissionStatusLabel(status: servicePermissionStatus(isEnabled: true, isActivated: fullDiskAccessGranted))`
  (the existing helper at lines 12-16 maps `nil` to `.checking`, which renders "Checking…").
- Line 90: `if fullDiskAccessGranted == false {`.
- `refresh()` (lines 127-130) keeps only `refreshToken += 1`.
- Next to `.formStyle(.grouped)` (line 119) add:

  ```swift
  .task(id: refreshToken) {
      fullDiskAccessGranted = await ServiceConfig.fullDiskAccessSatisfied(
          for: serverController.serviceConfigs
      )
  }
  ```

**3d. Test** — add `testFullDiskAccessSatisfied` to `ServiceFixesTests` in
`iMCPTests/AppModelTests.swift`. See "Test plan".

**Verify**:
- Build → exit 0.
- `grep -rn "= FullDiskAccess.isGranted" App/Views` → no matches.
- `grep -c "onChange(of: serviceConfigs.map" App/Views/ContentView.swift` → `1`.
- `Scripts/test.sh --only iMCPTests/ServiceFixesTests` → all pass.

Commit: `fix: menu and Permissions agree on Full Disk Access; stop probing in @State defaults`

### Step 4: General tab — refresh login-item state; delete the duplicate "MCP Server" section

All in `App/Views/SettingsView.swift`, `GeneralSettingsView` (lines 321-494).

**4a. Delete `Section("MCP Server") { ... }`** (lines 332-361) entirely. The
Clients tab keeps its "Connect a Client…" button and the Connect window shows
the command with a Copy button. Then:
- delete `@State private var copiedServerPath = false` (line 325);
- delete `let serverController: ServerController` (line 323);
- at the call site (lines 24-27) drop the `serverController:` argument, leaving
  `GeneralSettingsView(isMenuBarExtraInserted: isMenuBarExtraInserted)`.

**4b. State.** Replace lines 326-328 with:

```swift
    @State private var launchAtLogin = false
    @State private var alwaysOn = false
    @State private var approvalNeeded = false
    @State private var launchAtLoginError: String?
```

**4c. One read-back function**, placed above `setLaunchAtLogin`:

```swift
    /// What macOS says now. Registration can land in `.requiresApproval`, and
    /// the user approves or revokes in System Settings while this window is open.
    private func refreshLoginItems() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        alwaysOn = AlwaysOnService.isEnabled
        approvalNeeded =
            SMAppService.mainApp.status == .requiresApproval
            || AlwaysOnService.agent.status == .requiresApproval
    }
```

- In `setLaunchAtLogin`, replace everything after the `do/catch` (lines
  468-475: the comment, the assignment, and the `if`) with `refreshLoginItems()`.
- In `setAlwaysOn`, replace everything after the `do/catch` (lines 487-492)
  with `refreshLoginItems()`.
- Leave both `guard` lines and both `catch` bodies exactly as they are. The
  guards are what make the refresh safe: when `refreshLoginItems()` writes a
  toggle, `.onChange` calls the setter, and the guard returns because the
  value already matches the system.

**4d. Show the approval message from state.** Directly after the existing
`if let launchAtLoginError { ... }` block (lines 407-411) add:

```swift
                    if approvalNeeded {
                        Text("Approval needed: enable iMCP under System Settings → General → Login Items.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
```

**4e. Refresh on appear and on re-activation.** After `.formStyle(.grouped)`
(line 450) add:

```swift
        .task { refreshLoginItems() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshLoginItems()
        }
```

**Verify**:
- Build → exit 0.
- `grep -c "Approval needed" App/Views/SettingsView.swift` → `1`.
- `grep -n "copiedServerPath\|Section(\"MCP Server\")" App/Views/SettingsView.swift` → no matches.
- `grep -c "Connect a Client…" App/Views/SettingsView.swift` → `1`.

Commit: `fix: refresh login-item state when iMCP becomes active; drop the duplicate MCP Server section`

### Step 5: Menu rows — delete dead `isEnabled` branches, fold two row views into one, label the toggles

**5a. `App/Views/ContentView.swift`.** Delete `private struct MenuButton`
(lines 213-260) and `private struct StatusRow` (lines 262-306). Add one shell
and two builders. `MenuItemButtonStyle` (lines 308-330) stays untouched.

At file scope:

```swift
/// A row in the menu: runs its action, closes the menu, highlights on hover.
private struct MenuRow<Label: View>: View {
    @Binding var isMenuPresented: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHighlighted = false

    var body: some View {
        Button {
            action()
            isMenuPresented = false
        } label: {
            label
        }
        .buttonStyle(MenuItemButtonStyle(isHighlighted: isHighlighted))
        .onHover { isHighlighted = $0 }
    }
}

extension StatusSummary.Level {
    fileprivate var color: Color {
        switch self {
        case .ok: return .green
        case .attention: return .orange
        case .problem: return .red
        }
    }
}
```

Inside `ContentView`:

```swift
    private func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        MenuRow(isMenuPresented: $isMenuPresented, action: action) {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)

                Spacer()
            }
            .contentShape(Rectangle())
            .frame(height: 18)
            .padding(.vertical, 4)
        }
    }

    /// A status line: a colored dot, a title, and one line of detail.
    /// Clicking does the fix when there is one, and opens Settings otherwise.
    private func statusRow(_ summary: StatusSummary, action: @escaping () -> Void) -> some View {
        MenuRow(isMenuPresented: $isMenuPresented, action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(summary.level.color)
                    .frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.title)
                        .foregroundColor(.primary)
                    Text(summary.detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
    }
```

The two label bodies are the old ones copied verbatim (minus the
`isEnabled` opacity), so the menu must look pixel-identical. Do not "tidy"
the paddings.

Update the seven call sites: `StatusRow(summary: X, isMenuPresented: $isMenuPresented) { ... }`
→ `statusRow(X) { ... }` (three, at lines 91, 108, 121), and
`MenuButton("T", isMenuPresented: $isMenuPresented) { ... }` →
`menuButton("T") { ... }` (four, at lines 140, 145, 150, 154). Do not change
what any action closure does.

**5b. `App/Views/ServiceToggleView.swift`.**
- Delete line 20 (`@Environment(\.isEnabled) private var isEnabled`).
- Line 51: `.animation(.snappy, value: isOn || isEnabled)` → `.animation(.snappy, value: isOn)`.
- Delete line 54 (`.disabled(!isEnabled)`).
- Line 59: `.foregroundColor(isEnabled ? Color.primary : .primary.opacity(0.5))` → `.foregroundColor(.primary)`.
- Lines 110-125 become:

  ```swift
  private var buttonBackgroundColor: Color {
      isOn ? config.color : Color(NSColor.controlColor).opacity(colorScheme == .dark ? 0.8 : 0.2)
  }

  private var buttonForegroundColor: Color {
      isOn ? .white : .primary.opacity(0.7)
  }
  ```
- On the toggle `Button` (after `.frame(width: buttonSize, height: buttonSize)`, line 55) add:

  ```swift
  .accessibilityLabel(config.name)
  .accessibilityValue(isOn ? "On" : "Off")
  .accessibilityAddTraits(.isToggle)
  ```

**Verify**:
- Build → exit 0.
- `grep -rn "Environment(\\\\.isEnabled)" App/Views` → no matches.
- `grep -n "struct MenuButton\|struct StatusRow" App/Views/ContentView.swift` → no matches.
- `grep -c "isMenuPresented: \$isMenuPresented" App/Views/ContentView.swift` → `2` (the two builders).
- `grep -c "accessibility" App/Views/ServiceToggleView.swift` → `4`.

Commit: `refactor: one menu row view; drop never-true disabled branches; label service toggles for VoiceOver`

### Step 6: Connect window — no perpetual timer

`App/Views/ConnectClientWindow.swift`:
- Delete `@State private var now = Date()` (line 36), the `timer` property
  (line 38), and `expiryText(_:)` (lines 146-149).
- Replace the caption `Text(...)` at lines 86-89 with (modifiers at 90-93 unchanged):

  ```swift
  Text(
      "Expires in \(Text(pairingCode.expiresAt, style: .timer)) · single use. \(Text(verbatim: "Pass it as imcp-server --pair \(pairingCode.code), or set IMCP_PAIR_CODE for a spawned client."))"
  )
  ```
  `Text(_:style: .timer)` counts down by itself with no view invalidation
  from us. The second half is `verbatim` so the underscores in
  `IMCP_PAIR_CODE` are never read as Markdown. If the sentence differs from
  the one shown here, keep the live wording and only swap the
  `expiryText(...)` interpolation for `Text(pairingCode.expiresAt, style: .timer)`.
- Replace `.onReceive(timer) { ... }` (lines 107-112) with:

  ```swift
  .task(id: pairingCode?.expiresAt) {
      guard let expiresAt = pairingCode?.expiresAt else { return }
      try? await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow)))
      if !Task.isCancelled { pairingCode = nil }
  }
  ```

Do not use `Text(timerInterval:)`: its `ClosedRange<Date>` traps if the view
is re-evaluated after the code expired.

**Verify**:
- Build → exit 0.
- `grep -n "Timer.publish\|expiryText\|var now" App/Views/ConnectClientWindow.swift` → no matches.

Commit: `fix: stop the Connect window ticking once a second forever`

### Step 7: Sign Out asks first

**7a. `App/Views/ICloudSignInWindow.swift`.** Add at the end of the file
(internal, not private — Settings uses it too):

```swift
/// Signing out throws the stored session away, and getting it back costs the
/// password and a verification code. Both Sign Out buttons are this one.
struct ICloudSignOutButton: View {
    let session: ICloudSession
    @State private var confirming = false

    var body: some View {
        Button("Sign Out…") { confirming = true }
            .confirmationDialog("Sign out of iCloud?", isPresented: $confirming) {
                Button("Sign Out", role: .destructive) {
                    Task { await session.signOut() }
                }
            } message: {
                Text(
                    "Location stops working until you sign in again with your Apple ID password and a verification code."
                )
            }
    }
}
```

In `signedIn(accountName:)` replace the three-line `Button("Sign Out") { ... }`
(lines 173-175) with `ICloudSignOutButton(session: session)`.

**7b. `App/Views/SettingsView.swift`**, `ICloudAccountRow`: replace the
three-line `Button("Sign Out") { ... }` (lines 175-177) with
`ICloudSignOutButton(session: session)`. Keep the `.controlSize(.small)` and
`.glassButtonStyle()` that follow; both reach the inner button through the
environment.

**Verify**:
- Build → exit 0.
- `grep -rn "session.signOut()" App/Views` → exactly one match, in `ICloudSignInWindow.swift`.

Commit: `fix: confirm before signing out of iCloud`

### Step 8: Links point at this fork; small leftovers

**8a. `App/Views/SettingsView.swift`.** Add at file scope, under the imports:

```swift
private let repositoryURL = "https://github.com/cyberpapiii/iMCP"
```

- Line 433: `URL(string: repositoryURL)!`
- Line 438: `URL(string: repositoryURL + "/issues/new")!`
- Lines 677-681: `NSWorkspace.shared.open(URL(string: repositoryURL + "/blob/main/docs/find-my-people-setup.md")!)`
  (collapses the five-line call to one). First confirm
  `git ls-tree origin/main docs/find-my-people-setup.md` prints a blob line.

**8b. `SettingsView.swift`, `FindMyPeopleSettingsSection`.**
- Line 620: `Button("Status")` → `Button("Refresh")`.
- Delete the two identical "Cancel Setup" buttons (lines 649-654 and 659-664)
  from inside the `switch`, and add one after the `switch`'s closing brace,
  before `Button("Setup Guide")`:

  ```swift
  if [.handoffReady, .restorationRequired, .envelopeReady].contains(bootstrapState) {
      Button("Cancel Setup", role: .destructive) {
          Task {
              await FindMyPeopleBootstrap.shared.clearPreparedHandoff()
              await refresh()
          }
      }
  }
  ```
  Button order on screen is unchanged. Do not touch `case .configured`
  ("Clear Key" belongs to plan 046). If 046 already reshaped this `switch`,
  apply the same idea to what is there, or skip 8b's second bullet and say so.
- Delete the `@MainActor` attribute lines above `prepare()` (line 754) and
  `refresh()` (line 764), and change `Task { @MainActor in` to `Task {` at
  line 741. Leave `run`'s parameter type (line 738) as it is.

**8c. `App/Views/ConnectionApprovalView.swift`** — deletions only:
- lines 79-81 (`.background(...)`, `.cornerRadius(12)`, `.shadow(radius: 10)`);
- lines 147-148 (`isMovableByWindowBackground = false`, `titlebarAppearsTransparent = false`);
- lines 197-209 (the whole `#Preview { ... }`).

Keep `.fixedSize()` (line 78) and everything else.

**8d. `App/Views/LocationWindow.swift:491-503`.** Give the two chevrons names
by using the titled initialiser:

```swift
            Button("Previous Day", systemImage: "chevron.left") { model.shiftDay(by: -1) }
                .labelStyle(.iconOnly)
            Text(model.selectedDay, format: .dateTime.weekday(.wide).month().day())
                .font(.headline)
                .frame(minWidth: 180)
            Button("Next Day", systemImage: "chevron.right") { model.shiftDay(by: 1) }
                .labelStyle(.iconOnly)
                .disabled(model.isToday)
```

Nothing else in this file.

**Verify**:
- Build → exit 0.
- `grep -rn "mattt/iMCP\|dododosolutions" App` → no matches.
- `grep -c "Cancel Setup" App/Views/SettingsView.swift` → `1`.
- `grep -rn "#Preview" App` → no matches.
- `grep -c "chevron" App/Views/LocationWindow.swift` → same count as before this step (record it first; only the two header lines change form).

Commit: `fix: point Settings links at this fork; remove leftover chrome and duplicate buttons`

### Step 9: Format, lint, full test run

1. `swift format -i -r .` → exit 0. If it reformats files outside the in-scope
   list, `git checkout -- <those files>` and report it.
2. `swift format lint --strict --recursive .` → exit 0.
3. Build → exit 0.
4. `Scripts/test.sh` → all pass; app test count = baseline from step 0 + 4
   (four new test methods; one existing method extended).
5. `git status --short` → only in-scope files.
6. `git diff --shortstat main...HEAD -- App` → deletions exceed insertions.

Commit any formatting changes: `style: swift format`.

## Test plan

No new test file (test files need hand-made `project.pbxproj` entries; these
all fit existing classes).

**`iMCPTests/PairedClientStoreTests.swift`** (class `PairedClientStoreTests`;
model the new tests on `testFailedKeychainLoadDoesNotSaveOnAddRemoveOrReset`
at line 255, which shows how to build a failing storage):

```swift
    func testClientsIsNilWhenTheStoreCannotBeRead() {
        let unreadable = PairedClientStore(
            storage: PairedClientStorage(
                keychainLoad: { .failed(errSecInteractionNotAllowed) },
                keychainSave: { _ in true }
            )
        )
        XCTAssertNil(unreadable.clients)
    }

    func testReloadPicksUpAnExternalWrite() {
        let external = PairedClient(fingerprint: fingerprintB, label: "External", addedAt: Date())
        PairedClientStorage(userDefaults: userDefaults).add(external)

        store.reload()

        XCTAssertEqual(store.clients, [external])
    }
```

(`add` is `@discardableResult`, so the bare call compiles.)

**`iMCPTests/AppModelTests.swift`, class `AppStatusTests`** — append to
`testClientsRowCounts` (line 591):

```swift
        let unreadable = ClientsStatus.summary(pairedCount: nil)
        XCTAssertEqual(unreadable.level, .attention)
        XCTAssertEqual(
            unreadable.detail,
            "Could not read paired clients · each connection asks for approval"
        )
```

**`iMCPTests/AppModelTests.swift`, class `ServiceFixesTests`** — after
`testEveryRegisteredServiceHasAConfig` (model on it; it shows how to build
configs with fixed toggles):

```swift
    /// The IDs join the menu's toggles to the tool gate. They are type names,
    /// so renaming a service type must be a decision, not an accident.
    func testServiceIDsAreStable() {
        XCTAssertEqual(
            ServiceRegistry.descriptors.map(\.id),
            [
                "BrowserHistoryService", "CalendarService", "CallHistoryService",
                "CaptureService", "ContactsService", "LocationService", "MapsService",
                "MessageService", "NotesService", "NotificationsService", "PhotoService",
                "RemindersService", "ScreenTimeService", "ShortcutsService", "UtilitiesService",
            ]
        )
        let configs = ServiceRegistry.configureServices { _ in (get: { true }, set: { _ in }) }
        XCTAssertEqual(configs.map(\.id), ServiceRegistry.descriptors.map(\.id))
    }

    @MainActor
    func testFullDiskAccessSatisfied() async {
        let allOff = ServiceRegistry.configureServices { _ in (get: { false }, set: { _ in }) }
        let grantedResult = await ServiceConfig.fullDiskAccessSatisfied(for: allOff, granted: true)
        XCTAssertTrue(grantedResult)
        // No grant and nothing enabled that could stand in for it.
        let deniedResult = await ServiceConfig.fullDiskAccessSatisfied(for: allOff, granted: false)
        XCTAssertFalse(deniedResult)
    }
```

The ID list assumes a Debug build (Weather is compiled out of the registry in
Debug; tests run Debug only). If `testServiceIDsAreStable` fails because a
type name differs from the list, fix the **list** to match what the code
produces at `main` before your change (`git stash`, check, `git stash pop`);
the point is to pin today's strings, not to change them.

The UI changes (login-item refresh, confirmation dialog, timer, VoiceOver,
menu-row fold) have no unit-test seam in this repo and get none here. Their
gates are the build plus the grep checks in each step; see Maintenance notes
for the manual checklist a human should run.

Verification: `Scripts/test.sh` → all pass, including 4 new test methods and
1 extended one (app test count = baseline + 4; if the runner counts differently, report the numbers rather than forcing a match).

## Done criteria

ALL must hold:

- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `Scripts/test.sh` passes; `testClientsIsNilWhenTheStoreCannotBeRead`,
      `testReloadPicksUpAnExternalWrite`, `testServiceIDsAreStable`,
      `testFullDiskAccessSatisfied` exist and pass
- [ ] `grep -rn "= FullDiskAccess.isGranted\|Environment(\\\\.isEnabled)\|Timer.publish\|#Preview" App/Views` → no matches
- [ ] `grep -rn "mattt/iMCP\|dododosolutions" App` → no matches
- [ ] `grep -rn "computedServiceConfigs\|\.all()\.count\|revision" App/Controllers/PairedClientStore.swift App/Controllers/ServerController.swift App/Views` → no matches
- [ ] `grep -rn "String(describing: type(of" App/Controllers` → two matches (`ServiceRegistry.swift`, `ICloudSession.swift`)
- [ ] `grep -rn "session.signOut()" App/Views` → one match
- [ ] `git diff --shortstat main...HEAD -- App` shows more deletions than insertions
- [ ] `git status --short` shows no files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `git merge-base --is-ancestor 8165d29 HEAD` fails on your starting `main`:
  PR #61 is not merged. Do not rebase this plan onto the feature branch yourself.
- Plan 037 is not DONE and the operator has not told you to proceed.
- An excerpt in "Current state" no longer matches the code. Exception: steps
  5, 6, 7, and each bullet of step 8 are independent of each other and of
  steps 1-4; if one of them has drifted (another plan got there first), skip
  that step or bullet, say so in your report, and continue with the rest.
  Steps 1-4 are not skippable individually: step 3 uses step 2's
  `serviceConfigs`, and step 4's call-site edit assumes step 2 compiled.
- Any change seems to need an edit in `PairedClientStorage.swift` beyond
  `func all()`, or in `ServerNetworkManager.swift` beyond the four listed
  lines, or anything in `App/App.swift`.
- `store.contains(fingerprint:)` would have to read the new `clients` cache
  to make something work. It must keep asking `storage` directly; that is the
  pairing trust check.
- The build fails with an actor-isolation or `Sendable` diagnostic around
  `fullDiskAccessSatisfied` or `PairedClientStore.reload()` that one attempt
  does not fix. Report the exact diagnostic; do not add `nonisolated(unsafe)`
  or `@unchecked Sendable`.
- A step's verification fails twice after a reasonable fix attempt.
- Any test outside the ones this plan edits starts failing.

## Maintenance notes

- **Do not install as part of this plan.** The usual local-dev finish is
  `Scripts/install-local.sh run`; run it only if the operator asks.
- **Manual checks for a human after install** (none can be automated here):
  1. General tab: turn on Launch at Login, approve or disable iMCP under
     System Settings → General → Login Items, click back into iMCP's Settings:
     the toggle and the red "Approval needed" line follow without reopening.
  2. With Full Disk Access not granted but one database-backed service
     granted by re-selecting its database, the menu's status row and the
     Permissions tab's Full Disk Access row say the same thing.
  3. Connect a Client → Generate Pairing Code: the countdown runs, and the
     code disappears at zero.
  4. VoiceOver on a service row in the menu reads "<name>, On/Off, toggle".
  5. The menu looks the same as before (row heights, hover highlight).
  6. Sign Out in both places asks first.
- **Behaviour change to know about**: "Approval needed" is now shown whenever
  either login item is in `.requiresApproval`, not only in the seconds after
  the user flipped a toggle. That is the point (it used to vanish on reopening
  Settings while still true), but it also means a user who registered and then
  never approved sees it until they approve or turn the toggle off.
- **The fork is private.** `repositoryURL` now points at
  `https://github.com/cyberpapiii/iMCP`, verified to have issues enabled and
  to contain `docs/find-my-people-setup.md`, but visibility is PRIVATE: the
  three links work only for people with access to the repository. If this
  build is ever given to someone else, the links need a public target. That
  is an owner decision, not an executor one. (Decided 2026-11-09: the
  repository is public, so the links now work for everyone.)
- **`PairedClientStore.clients` is a view cache, not a trust source.**
  `contains(fingerprint:)` and everything in `PairedClientStorage` still read
  the store each time. Do not "optimise" the connection path onto the cache.
  Each mutation through the store reloads twice (once directly, once from its
  own notification); that is deliberate and cheap, since pairing changes are rare.
- **Not done, on purpose — Full Disk Access probed twice.** When the grant is
  missing, each database-backed service's `isActivated` is asked once by its
  menu row (`ServiceToggleView.swift`, `.task(id: isOn)`) and once by
  `fullDiskAccessSatisfied`. Deriving the status from the rows would mean
  lifting each row's `isServiceActivated` into a dictionary in `ContentView`
  and passing bindings down: more code than it removes, for a path that is
  skipped entirely when the grant is present. Revisit only if those probes
  show up in a profile.
- **Not done, on purpose — Weather in Debug.**
  `ServiceRegistry.swift:276` registers Weather only under
  `#if WEATHERKIT_AVAILABLE`, and that flag is set only in the Release
  configuration (`iMCP.xcodeproj/project.pbxproj:1045`). Debug compiles
  `Weather.swift` but never registers it, because Debug signing lacks the
  WeatherKit entitlement. Leave it; `testServiceIDsAreStable` and
  `testEveryRegisteredServiceHasAConfig` both assume the Debug list.
- **Not done, on purpose** — `let serverLog = Logger.server`
  (`ServerController.swift:10`, 77 call sites in five files) and
  `@AppStorage("isEnabled")` inside `ServerController` (`:34`). Removing
  either is churn across files other plans are editing, for no behaviour gain.
- **Service IDs are type names.** `ServiceRegistry.id(of:)` is now the only
  derivation. If a service type is ever renamed, `testServiceIDsAreStable`
  fails; update the list in the same commit. Nothing on disk stores these IDs.
- **Reviewer focus**: (1) `PairedClientStorage.all()` is the only change in
  that file; (2) the merged `.onChange` in `ContentView` still calls
  `updateServiceBindings()` on first appearance (`initial: true`), which is
  what seeds the tool gate after launch alongside `ServerController.init`;
  (3) the two menu-row label bodies are verbatim copies; (4) `git diff` for
  `SettingsView.swift` does not touch lines 466/484 (plan 042) or the
  Location history section (plan 047).
- **Neighbouring plans** editing the same files: 042 (error text in
  `SettingsView`), 043 (`ConnectionApprovalView`, pairing-code wording), 045
  (`ICloudSignInWindow`, menu Quit), 046 ("Clear Key", keychain enums), 047
  (`LocationWindow`, Location history section). Hunks are disjoint from this
  plan's; expect trivial rebases, not semantic conflicts.
