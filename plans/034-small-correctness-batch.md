# Plan 034: Make Utilities reachable, stop key clobbering, refresh the menu badge

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 17d7c72..HEAD -- App/Controllers/ServiceRegistry.swift CLI/ClientKeyStore.swift App/Views/ServiceToggleView.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW — three small, independent fixes with no shared surface
- **Depends on**: plans/029-verification-baseline.md
- **Category**: bug
- **Planned at**: commit `17d7c72`, 2026-08-07

## Why this matters

Three unrelated defects, each small, each with a concrete user-visible cost.
They are batched because each is a few lines and they touch disjoint files.

1. **`utilities_beep` can never be called.** `UtilitiesService` is registered
   and its enablement setting defaults to `true`, but it has no `ServiceConfig`
   — and tool gating resolves enabled services from the config list. So the
   service is advertised in the README, defaults to on, has no UI row, and its
   tool is filtered out of `ListTools` and rejected on `CallTool`. The code, the
   README, and the default setting all disagree.
2. **A transient read failure destroys the CLI's identity key.** Any failure to
   read the key file — a permissions hiccup, a partial write, a truncated read —
   falls through to *generating and writing a new key over it*. Because the app
   keys trust by public-key fingerprint, the client is instantly unpaired, every
   subsequent connection is rejected, and nothing explains why. The Keychain
   path (the release default) does not have this bug; only the file path does.
3. **The menu's permission badge never refreshes.** The `.task` that computes it
   has no `id:`, so it runs once per view identity. A service the user just
   fixed keeps showing the broken badge and the repair button; a service that
   just lost access keeps showing as fine. The Settings view does this
   correctly, so the two views disagree about the same service.

## Current state

### Defect 1 — `UtilitiesService` has no `ServiceConfig`

`UtilitiesService.shared` is in the registry list:

```swift
// App/Controllers/ServiceRegistry.swift:70-75
            PhotoService.shared,
            RemindersService.shared,
            ScreenTimeService.shared,
            ShortcutsService.shared,
            UtilitiesService.shared,
        ]
```

`configureServices` accepts the binding but never uses it:

```swift
// App/Controllers/ServiceRegistry.swift:97
        utilitiesEnabled: Binding<Bool>,
```

Confirm the gap yourself — this lists which services get a config:

```console
grep -n 'service: [A-Za-z]*Service.shared' App/Controllers/ServiceRegistry.swift
```

You will see 15 entries: BrowserHistory, Calendar, CallHistory, Capture,
Contacts, Location, Maps, Message, Notes, Notifications, Photo, Reminders,
ScreenTime, Shortcuts, Weather — **no Utilities**.

The gating path that makes this fatal: `ServerController.enabledServiceIDsSnapshot()`
derives enabled IDs from `computedServiceConfigs`, and
`App/Controllers/ServerNetworkManager.swift:492-495` filters tool definitions by
`enabledServiceIDs.contains(definition.serviceID)`. No config → never in the set
→ tools invisible and uncallable.

The setting exists and defaults on:

```swift
// App/Controllers/ServerController.swift:55
    @AppStorage("utilitiesEnabled") private var utilitiesEnabled = true  // Default enabled
```

The service and its tool:

```swift
// App/Services/Utilities.swift:7-13
final class UtilitiesService: Service {
    static let shared = UtilitiesService()

    var tools: [Tool] {
        Tool(
            name: "utilities_beep",
            description: "Play a system sound",
```

The `ServiceConfig` shape to copy — note Shortcuts has **no** `permissionGuidance`,
which is the right model for Utilities since it needs no TCC permission:

```swift
// App/Controllers/ServiceRegistry.swift:234-241
            ServiceConfig(
                name: "Shortcuts",
                iconName: "square.2.layers.3d",
                color: .indigo,
                service: ShortcutsService.shared,
                binding: shortcutsEnabled
            ),
        ]
```

### Defect 2 — key file clobbered on any read failure

```swift
// CLI/ClientKeyStore.swift:45-57
    private static func loadSigningKeyFromFile(at path: String) -> P256.Signing.PrivateKey? {
        let url = URL(fileURLWithPath: path)
        guard let rawKey = try? Data(contentsOf: url), rawKey.count == 32 else {
            return createSigningKeyFile(at: url)
        }
        return try? P256.Signing.PrivateKey(rawRepresentation: rawKey)
    }

    private static func createSigningKeyFile(at url: URL) -> P256.Signing.PrivateKey? {
        let privateKey = P256.Signing.PrivateKey()
        guard writeSigningKeyFile(privateKey, at: url) else { return nil }
        return privateKey
    }
```

`try?` collapses "file does not exist yet" and "file exists but could not be
read" into the same branch, and `writeSigningKeyFile` uses `.atomic`, replacing
whatever was there.

Contrast the Keychain path, which is correct — it only creates when the read
returns `nil`:

```swift
// CLI/ClientKeyStore.swift:59-67
    private static func loadSigningKeyFromKeychain() -> P256.Signing.PrivateKey? {
        if let existing = readKeychainData() {
            return try? P256.Signing.PrivateKey(rawRepresentation: existing)
        }

        let privateKey = P256.Signing.PrivateKey()
        guard persistSigningKey(privateKey) else { return nil }
        return privateKey
    }
```

This file path is selected by the `IMCP_KEY_FILE` environment variable
(`CLI/ClientKeyStore.swift:33-39`).

### Defect 3 — menu badge `.task` has no `id:`

```swift
// App/Views/ServiceToggleView.swift:68-70
        .task {
            isServiceActivated = await config.isActivated
        }
```

The correct pattern already exists in the Settings view — it keys the task on a
composite `RefreshID` so it re-runs when the enablement or a refresh token
changes:

```swift
// App/Views/SettingsView.swift:148-155 (the exemplar to follow)
        .task(id: RefreshID(refreshToken: refreshToken, isEnabled: isEnabled)) { ... }
```

Read that block in full before editing — match its shape.

### Conventions

- `swift format`: 4-space indent, 120-column limit.
- Tests are plain `XCTest` in `iMCPTests/`.
- **The `iMCP` app target uses a synchronized file group**, so new files under
  `App/` are picked up automatically. **Test targets are hand-maintained** in
  `iMCP.xcodeproj/project.pbxproj` — a new test file will silently never run
  unless four entries are added (see `plans/030-wire-orphaned-tests.md`). Add
  test cases to existing test files.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| App tests | `xcodebuild test -scheme iMCP -destination "platform=macOS"` | exit 0, `TEST SUCCEEDED` |
| CLI tests | `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` | exit 0, `TEST SUCCEEDED` |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

`-quiet` suppresses the success marker — **success is exit code 0**.

## Scope

**In scope** (the only files you should modify):
- `App/Controllers/ServiceRegistry.swift`
- `CLI/ClientKeyStore.swift`
- `App/Views/ServiceToggleView.swift`
- `iMCPTests/ClaudeDesktopConfigTests.swift` (for the registry test — it already
  hosts `ServiceFixesTests`)
- `CLITests/CLIBootstrapTests.swift` (for the key-store tests — it already
  covers `ClientKeyStore` rotation through the `IMCP_KEY_FILE` seam)

**Out of scope** (do NOT touch, even though they look related):
- `App/Controllers/ServerController.swift` — it already passes
  `utilitiesEnabled` correctly; the bug is entirely on the receiving side.
- `App/Services/Utilities.swift` — the service is fine, it is just unreachable.
- `App/Views/SettingsView.swift` — it is the pattern to copy, not a file to edit.
- Gating `IMCP_KEY_FILE` to debug builds. It is a legitimate separate hardening
  question (see Maintenance notes) and changing it here would break the
  operator's dev flow without warning.
- Any change to `App/Controllers/ServerNetworkManager.swift`'s gating logic.

## Git workflow

- Branch: `advisor/034-small-correctness-batch`
- Conventional commits — **one commit per defect**, e.g.
  `fix: register UtilitiesService so utilities_beep is reachable`.
- Do NOT push or open a PR unless the operator asks.

## Steps

### Step 1: Give `UtilitiesService` a `ServiceConfig`

Add a `ServiceConfig` entry for `UtilitiesService.shared` to the `configs` array
in `configureServices`, wired to the already-present `utilitiesEnabled` binding.
Model it on the Shortcuts entry quoted above: no `permissionGuidance` (the
service needs no TCC permission — it plays a system sound). Choose an
appropriate `name: "Utilities"`, an SF Symbol for `iconName`, and a `color`
distinct from its neighbors.

Place it in the array so the surrounding entries stay alphabetical by name —
after Shortcuts, before the `#if WEATHERKIT_AVAILABLE` block.

**Verify**:
```console
grep -c "service: UtilitiesService.shared" App/Controllers/ServiceRegistry.swift
grep -n 'service: [A-Za-z]*Service.shared' App/Controllers/ServiceRegistry.swift | wc -l
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ `1`, `16`, `exit=0`.

### Step 2: Add a registry-consistency test

In `iMCPTests/ClaudeDesktopConfigTests.swift`, inside the existing
`ServiceFixesTests` class, add a test asserting that **every** service in
`ServiceRegistry.services` has a corresponding `ServiceConfig`. Build the
configs by calling `ServiceRegistry.configureServices(...)` with constant
bindings (`.constant(true)` for each parameter), then compare the two sets of
service identifiers.

This is the test that would have caught the bug, and it prevents the next
service from being added to one list but not the other.

Note the `#if WEATHERKIT_AVAILABLE` conditional: `WeatherService` is registered
and configured only in Release builds, and tests run against Debug. Since both
the `services` array and the `configs` array are gated by the *same* compilation
condition, a set-equality assertion holds in both configurations — but confirm
that when you write it, and if it does not hold, assert that configs ⊇ services
minus Weather rather than weakening the test to nothing.

**Verify**: `xcodebuild test -scheme iMCP -destination "platform=macOS" ; echo "exit=$?"` → `exit=0`, new test passes.

### Step 3: Never overwrite an unreadable key file

In `CLI/ClientKeyStore.swift:45-51`, distinguish "the file does not exist" from
"the file exists but could not be read or is the wrong length":

- Create a new key **only** when the file genuinely does not exist. Check with
  `FileManager.default.fileExists(atPath:)` before attempting the read, or
  catch the read error and match `CocoaError.fileNoSuchFile` / `POSIXError.ENOENT`.
- For any other read failure, and for a file whose contents are not exactly 32
  bytes, return `nil` **without writing**. A `nil` key means the CLI does not
  authenticate — the user sees an approval prompt, which is recoverable — rather
  than silently destroying a paired identity, which is not.
- Log an actionable message on that path so the failure is diagnosable rather
  than silent. Match the logging style already used in the CLI.

**Verify**:
```console
grep -c "fileExists" CLI/ClientKeyStore.swift    # expect >= 1
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ `≥ 1` and `exit=0`.

### Step 4: Test the key-store paths

In `CLITests/CLIBootstrapTests.swift` — which already drives `ClientKeyStore`
through the `IMCP_KEY_FILE` environment seam — add cases:

1. **Missing file creates a key**: point `IMCP_KEY_FILE` at a nonexistent path
   in a temp directory; `loadSigningKey()` returns a key and the file now exists.
   (This is the existing behavior; the test pins it so Step 3 does not break it.)
2. **Corrupt file is not overwritten**: write 5 bytes of garbage to the path;
   `loadSigningKey()` returns `nil` **and** the file's contents are unchanged.
   This is the regression test for the defect.
3. **Valid key round-trips**: write a known key, load it, assert the same
   fingerprint via `ClientKeyStore.publicKeyFingerprint(for:)`.

Note that these tests mutate the process-global environment via `setenv`, as the
existing tests in this file already do — follow the same setUp/tearDown
discipline so they do not leak into other tests.

**Verify**: `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS" ; echo "exit=$?"` → `exit=0` with 3 new tests.

### Step 5: Make the menu badge re-check

In `App/Views/ServiceToggleView.swift:68-70`, give the `.task` an `id:` so it
re-runs when the service's enablement changes, following the `RefreshID` pattern
at `App/Views/SettingsView.swift:148-155`.

At minimum key it on `config.binding.wrappedValue`. If the menu should also
re-check when reopened, thread through a refresh token the way `SettingsView`
does — but do **not** introduce a timer or polling loop.

**Verify**:
```console
grep -c ".task(id:" App/Views/ServiceToggleView.swift    # expect 1
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ `1` and `exit=0`.

### Step 6: Run the full gate

```console
swift format -i -r .
swift format lint --strict --recursive . ; echo "exit=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS" ; echo "exit=$?"
xcodebuild test -scheme iMCP -destination "platform=macOS" ; echo "exit=$?"
```

**Verify**: all four print `exit=0`.

## Test plan

- **New** in `iMCPTests/ClaudeDesktopConfigTests.swift` (`ServiceFixesTests`):
  registry/config set-equality test (Step 2).
- **New** in `CLITests/CLIBootstrapTests.swift`: missing-file-creates,
  corrupt-file-preserved, valid-key-round-trip (Step 4).
- **Structural patterns**: `ServiceFixesTests` for the registry test;
  the existing `IMCP_KEY_FILE` tests in `CLIBootstrapTests.swift` for the key
  tests.
- **Manual verification** (no automated coverage): the Utilities row appears in
  the menu and `utilities_beep` is callable from an MCP client; the menu badge
  updates after toggling a service. State these explicitly in your report.
- Verification: both test schemes exit 0 with 4 new tests total.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "service: UtilitiesService.shared" App/Controllers/ServiceRegistry.swift` → `1`
- [ ] `grep -n 'service: [A-Za-z]*Service.shared' App/Controllers/ServiceRegistry.swift | wc -l` → `16`
- [ ] `grep -c "fileExists" CLI/ClientKeyStore.swift` → `≥ 1`
- [ ] `grep -c ".task(id:" App/Views/ServiceToggleView.swift` → `1`
- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `xcodebuild test -scheme iMCP -destination "platform=macOS"` exits 0 with the new registry test
- [ ] `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` exits 0 with 3 new key tests
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row for 034 updated

## STOP conditions

Stop and report back (do not improvise) if:

- The Step 2 registry test fails for a service **other** than Utilities — that
  means a second service is also unreachable, which is a new finding, not
  something to quietly fix here.
- The `#if WEATHERKIT_AVAILABLE` conditional makes a clean set-equality
  assertion impossible in Debug. Report your reasoning before weakening it.
- Adding the `.task(id:)` causes the permission check to run repeatedly in a
  loop (visible as repeated TCC probes or UI flicker) — revert and report.
- The corrupt-file test (Step 4, case 2) shows the file **is** still being
  overwritten after your Step 3 change; that means the error-matching branch is
  wrong.
- You conclude a new test **file** is needed — it would silently never run.

## Maintenance notes

For the human/agent who owns this code after the change lands:

- **A reviewer should scrutinize**: that the Utilities `ServiceConfig` has no
  `permissionGuidance` (it needs no permission, and adding one would show a
  spurious repair prompt), and that Step 3's error matching really distinguishes
  ENOENT from every other failure — that distinction is the whole fix.
- **Deferred, related to defect 2**: `IMCP_KEY_FILE` is honored in **all** build
  configurations, though its doc comment at `CLI/ClientKeyStore.swift:5-9` calls
  it debug/dev only. Whoever controls the CLI's environment can relocate the
  client identity key to a readable path. Wrapping that branch in `#if DEBUG`
  is the fix; it is out of scope here because it would break the operator's
  local dev flow without warning and deserves its own decision.
- **Deferred, related to defect 3**: the same permission probes run from three
  places with no shared cache — the menu rows
  (`App/Views/ServiceToggleView.swift:68-70`), the Full Disk Access banner
  (`App/Views/ContentView.swift:193-209`, which loops **serially**), and the
  Settings rows (`App/Views/SettingsView.swift:148-155`). Adding the `id:` here
  makes the badge correct but slightly increases probe frequency. A shared
  `@MainActor` permission-status store, invalidated on successful activation and
  on `didBecomeActiveNotification`, is the real fix and should be its own plan.
- **Alternative considered for defect 1**: deleting `UtilitiesService` entirely
  (registry entry, parameter, `@AppStorage` key, README row) instead of wiring
  it up. Registering it was chosen because the setting defaults to `true` and
  the README documents the service, so the evident intent was for it to ship. If
  the operator would rather retire it, that is a small, clean reversal of Step 1.
