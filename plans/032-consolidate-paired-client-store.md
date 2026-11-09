# Plan 032: Give the paired-client trust store a single, read-through owner

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 17d7c72..HEAD -- App/Controllers/PairedClientStore.swift App/Controllers/ServerNetworkManager.swift App/Views/SettingsView.swift iMCPTests/PairedClientStoreTests.swift iMCPTests/ServerNetworkManagerAuthTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED — this is the trust store that decides which clients skip the approval prompt. A mistake either drops the user's pairings (annoying, recoverable by re-pairing) or auto-approves a client that should be prompted (a security regression). Do not change the on-disk encoding.
- **Depends on**: plans/029-verification-baseline.md, plans/030-wire-orphaned-tests.md
- **Category**: security
- **Planned at**: commit `17d7c72`, 2026-08-07

## Why this matters

The set of paired clients — the list of cryptographic fingerprints allowed to
use the user's Messages, Contacts, Photos, Location, camera and microphone
**without an approval prompt** — is currently stored and mutated by two
independent implementations that do not observe each other. They share only a
duplicated string literal, `"pairedClients"`.

Three concrete defects follow from that:

1. **Lost updates.** `PairedClientStore` snapshots the stored bytes **once at
   init** and never re-reads them. Any pairing added by `ServerNetworkManager`
   while a store instance is alive is silently erased the next time the user
   adds or removes a client in Settings — the store re-encodes an array built
   from its stale snapshot. The reverse also happens: a client the user just
   removed in Settings can reappear.
2. **A rename splits the store in two.** The key is a bare literal inside
   `ServerNetworkManager`, so renaming `PairedClientStore.storageKey` compiles
   cleanly, and the UI would show zero paired clients while the network manager
   kept auto-approving them.
3. **Tests scribble on the operator's real data.**
   `iMCPTests/ServerNetworkManagerAuthTests.swift` hardcodes the same key and
   mutates **`UserDefaults.standard`** — the real defaults domain — because the
   network manager offers no injection point. A crash between `setUp` and
   `tearDown` leaves the user's real pairings wiped or replaced with fixtures.

Consolidating behind one read-through owner fixes all three and is a
prerequisite for the deeper hardening noted at the end.

## Current state

### The two implementations

```swift
// App/Controllers/PairedClientStore.swift:1-24 — the UI's store
@MainActor
final class PairedClientStore: ObservableObject {
    static let storageKey = "pairedClients"

    private let userDefaults: UserDefaults
    @Published private var storedData: Data

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.storedData = userDefaults.data(forKey: Self.storageKey) ?? Data()
    }

    private var clients: [PairedClient] {
        get {
            (try? JSONDecoder().decode([PairedClient].self, from: storedData)) ?? []
        }
        set {
            storedData = (try? JSONEncoder().encode(newValue)) ?? Data()
            userDefaults.set(storedData, forKey: Self.storageKey)
        }
    }
```

Note the bug precisely: the getter decodes `storedData`, which is only ever
assigned at `init` and by this setter. External writes are invisible.

Its remaining API (`App/Controllers/PairedClientStore.swift:26-49`) is
`all()`, `contains(fingerprint:)`, `add(_:)`, `remove(fingerprint:)`, `reset()`.

```swift
// App/Controllers/ServerNetworkManager.swift:23 — the duplicate key
    private let pairedClientsStorageKey = "pairedClients"
```

```swift
// App/Controllers/ServerNetworkManager.swift:287-317 — the duplicate implementation
    private func addPairedClient(fingerprint: String, label: String) {
        guard var clients = loadPairedClients() else {
            let client = PairedClient(fingerprint: fingerprint, label: label, addedAt: Date())
            persistPairedClients([client])
            return
        }

        guard !clients.contains(where: { $0.fingerprint == fingerprint }) else { return }
        clients.append(PairedClient(fingerprint: fingerprint, label: label, addedAt: Date()))
        persistPairedClients(clients)
    }

    private func loadPairedClients() -> [PairedClient]? {
        guard
            let data = UserDefaults.standard.data(forKey: pairedClientsStorageKey),
            let clients = try? JSONDecoder().decode([PairedClient].self, from: data)
        else {
            return nil
        }
        return clients
    }

    private func persistPairedClients(_ clients: [PairedClient]) {
        guard let data = try? JSONEncoder().encode(clients) else { return }
        UserDefaults.standard.set(data, forKey: pairedClientsStorageKey)
    }

    private func containsPairedFingerprint(_ fingerprint: String) -> Bool {
        guard let clients = loadPairedClients() else { return false }
        return clients.contains { $0.fingerprint == fingerprint }
    }
```

### The isolation problem you must solve

`PairedClientStore` is `@MainActor` (it is an `ObservableObject` driving
SwiftUI). `ServerNetworkManager` is an `actor`. The network manager calls
`containsPairedFingerprint` and `addPairedClient` **synchronously** from inside
its own actor-isolated code (around `App/Controllers/ServerNetworkManager.swift:257-269`),
so it cannot simply `await` a `@MainActor` object there without restructuring
that call path.

**The intended design**: extract a small, non-isolated `struct` that owns the
key and the encode/decode/dedupe logic against an injected `UserDefaults`, and
have **both** `PairedClientStore` and `ServerNetworkManager` hold one. Because
`UserDefaults` is itself thread-safe and every operation becomes a fresh
read-modify-write, no lost update survives, and neither existing isolation
domain has to change.

### Consumers you must not break

- `App/Views/SettingsView.swift:242` constructs a `PairedClientStore` in
  `GeneralSettingsView` and drives the paired-clients list from it. It relies on
  `ObservableObject` change notifications to refresh — **preserve the
  `@Published` change signal**, or the Settings list stops updating.
- `App/Controllers/ServerNetworkManager.swift` auto-approval paths at `:257-263`
  and `:408-413` depend on `containsPairedFingerprint`.

### Conventions

- `PairedClient` is `Codable` (`App/Models/PairedClient.swift`) with
  `fingerprint`, `label`, `addedAt`. **Do not change its shape** — the encoding
  must stay byte-compatible so existing pairings survive the upgrade.
- Tests use plain `XCTest`. `iMCPTests/PairedClientStoreTests.swift` already
  shows the correct isolation pattern: a throwaway
  `UserDefaults(suiteName:)` per test. Model new tests on it.
- `swift format`: 4-space indent, 120-column limit.

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

**In scope** (the only files you should modify or create):
- `App/Controllers/PairedClientStore.swift`
- `App/Controllers/ServerNetworkManager.swift` (only the paired-client
  storage members named above — `:23`, `:287-317`, and their call sites)
- `iMCPTests/PairedClientStoreTests.swift`
- `iMCPTests/ServerNetworkManagerAuthTests.swift`
- A new file for the extracted storage type, if you choose to create one —
  `App/Controllers/PairedClientStorage.swift`. **The `iMCP` app target uses a
  synchronized file group, so a new file under `App/` is picked up
  automatically — no `project.pbxproj` edit is needed.** (Test files are the
  opposite; see STOP conditions.)

**Out of scope** (do NOT touch, even though they look related):
- `App/Models/PairedClient.swift` — changing the model changes the on-disk
  encoding and would drop every existing pairing.
- Moving the trust store out of `UserDefaults` into the Keychain. That is a
  real and more important hardening step, but it is a **separate** change with
  its own migration risk; doing both at once makes a failure impossible to
  diagnose. See Maintenance notes.
- The approval and auth-preamble logic itself
  (`App/Controllers/ServerNetworkManager.swift:230-285`, `:381-457`) — you are
  changing where the fingerprint list is *stored*, not who is trusted.
- `App/Views/SettingsView.swift` — it should keep compiling unchanged. If it
  does not, you have altered `PairedClientStore`'s public API; see STOP
  conditions.

## Git workflow

- Branch: `advisor/032-consolidate-paired-client-store`
- Conventional commits, e.g.
  `refactor: route paired-client trust store through a single owner`.
- Commit per step.
- Do NOT push or open a PR unless the operator asks.

## Steps

### Step 1: Extract the storage type

Create a non-isolated `struct PairedClientStorage` (in
`App/Controllers/PairedClientStorage.swift`, or at the top of
`PairedClientStore.swift` if you prefer one fewer file — either is acceptable).

It owns:
- the single `static let storageKey = "pairedClients"`,
- an injected `let userDefaults: UserDefaults` with a `.standard` default,
- `func all() -> [PairedClient]` — **reads from `userDefaults` every call**,
  decodes, returns `[]` on absent or undecodable data,
- `func contains(fingerprint: String) -> Bool`,
- `@discardableResult func add(_ client: PairedClient) -> Bool` — fresh read,
  dedupe by `fingerprint`, append, write back; returns whether it added,
- `func remove(fingerprint: String)`,
- `func reset()`.

The critical property: **every method does a fresh read from `UserDefaults`.**
No cached array, no cached `Data`. That is what eliminates the lost update.

Make the type `Sendable` (it holds only a `UserDefaults` reference and a static
string) so the `actor` can hold one without a concurrency diagnostic.

**Verify**: `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"` → `exit=0`.

### Step 2: Reimplement `PairedClientStore` on top of it

Keep `PairedClientStore` as the `@MainActor ObservableObject` the Settings view
uses, and keep its five public methods (`all`, `contains`, `add`, `remove`,
`reset`) with identical signatures — `SettingsView.swift` must compile
untouched.

Changes inside it:
- Replace the `storedData` snapshot with a `PairedClientStorage` instance.
- Delegate every method to the storage.
- Keep an `@Published` property as a **change ticker only** (e.g.
  `@Published private var revision = 0`, incremented after each mutation), so
  SwiftUI still refreshes. It must no longer be the source of truth.
- Keep `static let storageKey` as a forwarding alias to
  `PairedClientStorage.storageKey` if anything references it, so no caller
  breaks. Check with
  `grep -rn "PairedClientStore.storageKey" --include=*.swift .`

**Verify**:
```console
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
git diff --name-only | grep -c "SettingsView.swift"   # expect 0 — it must not need edits
```
→ `exit=0` and `0`.

### Step 3: Route `ServerNetworkManager` through the same storage

In `App/Controllers/ServerNetworkManager.swift`:

- Delete `private let pairedClientsStorageKey` (`:23`).
- Delete `loadPairedClients()`, `persistPairedClients(_:)` (`:299-312`).
- Replace `addPairedClient(fingerprint:label:)` and
  `containsPairedFingerprint(_:)` with one-line delegations to a
  `PairedClientStorage` instance held by the actor.
- Add an injection point so tests can supply a throwaway `UserDefaults`: give
  the actor a stored `private let pairedClientStorage: PairedClientStorage`
  initialized from an initializer parameter defaulting to
  `PairedClientStorage()`. Follow the existing initializer's style in this file.

Behavior must be preserved exactly: `addPairedClient` still dedupes by
fingerprint, and `containsPairedFingerprint` still returns `false` when nothing
is stored.

**Verify**:
```console
grep -c "pairedClientsStorageKey" App/Controllers/ServerNetworkManager.swift   # expect 0
grep -c "UserDefaults.standard" App/Controllers/ServerNetworkManager.swift     # expect 0
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ `0`, `0`, `exit=0`.

### Step 4: Stop the auth tests from writing real user defaults

In `iMCPTests/ServerNetworkManagerAuthTests.swift`:

- Delete the hardcoded `pairedClientsKey = "pairedClients"` and the
  backup/restore of `UserDefaults.standard` in `setUp`/`tearDown`.
- Construct a per-test `UserDefaults(suiteName:)` — use a unique suite name per
  test, and call `removePersistentDomain(forName:)` in `tearDown`. Copy the
  pattern from `iMCPTests/PairedClientStoreTests.swift:15-18`.
- Inject that suite into the `ServerNetworkManager` under test via the
  parameter added in Step 3.

**Verify**:
```console
grep -c "UserDefaults.standard" iMCPTests/ServerNetworkManagerAuthTests.swift   # expect 0
xcodebuild test -scheme iMCP -destination "platform=macOS" ; echo "exit=$?"
```
→ `0` and `exit=0`.

### Step 5: Add the lost-update regression test

In `iMCPTests/PairedClientStoreTests.swift`, add a test that fails against the
old implementation and passes against the new one:

1. Create one `UserDefaults(suiteName:)`.
2. Construct a `PairedClientStore` over it (this is what captured a stale
   snapshot before).
3. Write a **second** client directly through a separate `PairedClientStorage`
   over the same suite — simulating `ServerNetworkManager` pairing a client
   while the Settings window is open.
4. Now call `store.add(_:)` with a third client.
5. Assert `store.all()` contains **all three** fingerprints.

Under the old code the second client is erased at step 4. Name the test
something explicit, e.g.
`testExternalPairingSurvivesSubsequentStoreWrite`.

Also add: `testContainsReflectsExternalWrite` — a fingerprint written through
a separate storage instance is visible to `store.contains(fingerprint:)`
without recreating the store.

**Verify**: `xcodebuild test -scheme iMCP -destination "platform=macOS" ; echo "exit=$?"` → `exit=0` with 2 new tests passing.

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

- **New** in `iMCPTests/PairedClientStoreTests.swift`:
  `testExternalPairingSurvivesSubsequentStoreWrite` (the lost-update
  regression) and `testContainsReflectsExternalWrite`.
- **Modified** in `iMCPTests/ServerNetworkManagerAuthTests.swift`: all existing
  tests keep their assertions but run against an injected throwaway
  `UserDefaults` suite instead of `UserDefaults.standard`.
- **Structural pattern**: `iMCPTests/PairedClientStoreTests.swift` — it already
  does per-test suite isolation correctly.
- **Existing coverage that must keep passing unchanged**:
  `iMCPTests/ServerNetworkManagerGatingTests.swift` and
  `iMCPTests/ConnectionApprovalQueueTests.swift` — these guard that unapproved
  connections cannot list or call tools. If either breaks, you have changed
  trust behavior, not just storage.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "pairedClientsStorageKey" App/Controllers/ServerNetworkManager.swift` → `0`
- [ ] `grep -c "UserDefaults.standard" App/Controllers/ServerNetworkManager.swift` → `0`
- [ ] `grep -c "UserDefaults.standard" iMCPTests/ServerNetworkManagerAuthTests.swift` → `0`
- [ ] `grep -rn "\"pairedClients\"" --include=*.swift App/ | wc -l` → `1` (the single owner)
- [ ] `git diff --name-only` does **not** include `App/Views/SettingsView.swift`
- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `xcodebuild test -scheme iMCP -destination "platform=macOS"` exits 0, including the 2 new tests
- [ ] `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` exits 0
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row for 032 updated

## STOP conditions

Stop and report back (do not improvise) if:

- `App/Views/SettingsView.swift` stops compiling. That means you changed
  `PairedClientStore`'s public API; revert to the five original signatures.
- `ServerNetworkManagerGatingTests` or `ConnectionApprovalQueueTests` starts
  failing — you have altered trust behavior, not just storage.
- Making `ServerNetworkManager` use the storage requires making its
  `addPairedClient`/`containsPairedFingerprint` call sites `async`, cascading
  into the auth path at `:230-285`. Report before restructuring that path; it
  is the security-critical spine and is out of scope here.
- You conclude the `PairedClient` model or its JSON encoding must change.
- You need to add a **test** file: test targets are hand-maintained in
  `iMCP.xcodeproj/project.pbxproj` and a new test file will silently never run
  unless it is added there (four entries — see `plans/030-wire-orphaned-tests.md`).
  Prefer adding cases to the two existing test files named in scope.
- The Settings paired-clients list stops refreshing after a pairing (the
  `@Published` change signal was lost). This is not caught by any automated
  test — if you cannot verify it, say so explicitly in your report.

## Maintenance notes

For the human/agent who owns this code after the change lands:

- **A reviewer should scrutinize**: that every `PairedClientStorage` method
  reads from `UserDefaults` fresh (no caching reintroduced), that dedupe-by-
  fingerprint behavior is unchanged, and that the `@Published` ticker still
  fires so the Settings list refreshes.
- **The bigger deferred fix**: this trust store lives in `UserDefaults`, and the
  app is **not sandboxed** (`ENABLE_APP_SANDBOX = NO` at
  `iMCP.xcodeproj/project.pbxproj:734` and `:800`), so its preference domain is
  writable by any same-user process. Injecting a fingerprint there grants
  silent, permanent, prompt-free access to every enabled service — which
  defeats the pairing design from plans 025–028. Consolidating to one owner
  (this plan) is the prerequisite that makes that migration a single-file
  change. The fix is either the Keychain (generic password,
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) or an HMAC over the list
  under a Keychain-held key, refusing auto-approval when the MAC does not
  verify. Plan it next; it needs a migration path for existing pairings.
- **Related, not fixed here**: `App/Views/SettingsView.swift:373-378` has a
  private `truncatedFingerprint(_:)` duplicating
  `truncatedClientFingerprint(_:)` in
  `App/Shared/ConnectionApprovalPairing.swift:21-24`. Users compare that
  truncation against `imcp-server --fingerprint` output, so drift between the
  two copies would show one key as two different clients.
