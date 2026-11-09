# Plan 046: Find My People setup fails closed, cleans up after itself, and survives transient faults

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **ABSOLUTE RULE (read before anything else)**: Find My People bootstrap is
> human-only. You must NEVER execute `Scripts/find-my-people-bootstrap.sh`,
> `Scripts/verify-find-my-people-security.sh`,
> `Scripts/observe-find-my-people.sh`, or load `Scripts/find_my_people_key.py`
> into LLDB — in any mode, including `--dry-run`, `status`, and `--help`. You
> must never run `bputil`, `csrutil`, `nvram`, `lldb`, `DevToolsSecurity`, or
> `sudo`, never reboot, never enter Recovery, never type a password. For the
> scripts you may edit text and run only the two syntax checks listed in
> "Commands you will need". Every behavioural check of a script is marked
> **HUMAN STEP** and is performed by the owner, not by you.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- App/Services/Location/FindMyPeopleBootstrap.swift App/Services/Location/LocalStoragePeopleProvider.swift App/Services/Location/LocalStorageKeyStorage.swift App/Services/Location/LocationHistoryStore.swift App/Services/Location/ICloudCredentialStorage.swift App/Controllers/PairedClientStorage.swift App/Models/KeychainItem.swift App/Views/SettingsView.swift Scripts/find-my-people-bootstrap.sh Scripts/verify-find-my-people-security.sh Scripts/find_my_people_key.py Scripts/observe-find-my-people.sh docs/find-my-people-setup.md iMCPTests/LocalStoragePeopleProviderTests.swift iMCPTests/ICloudAuthPlumbingTests.swift iMCPTests/ICloudAuthFlowTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. `App/Views/SettingsView.swift` is
> also edited by plans 047 and 048; a diff there is expected if they landed
> first — re-locate the excerpts by text, not by line number.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (Part A: LOW, unit-tested. Part B: MED, edits privileged
  scripts that no agent may run; verified only by the owner.)
- **Depends on**: plans/037-isolate-tests-from-real-state.md
- **Category**: security
- **Planned at**: commit `8165d29`, 2026-10-12

## Why this matters

Find My People setup asks the owner to weaken macOS startup security for a few
minutes and then proves it was restored. The proof today is not fail-closed:
the verifier greps for substrings (`Full Security`, `status: enabled`) in
output that includes stderr, and treats an unreadable `boot-args` as "no boot
args". The capture wrapper puts a root debugger in a background process group
where Ctrl-C cannot reach it and where the wrapper's own cleanup raises
instead of terminating it. In the app, cancelling setup deletes the prepared
state with a query that does not match how it was stored and ignores the
result; a normal stale WAL frame makes People unreadable; one transient
Keychain failure at login sticks until relaunch; and "deleted" location
history stays readable in SQLite free pages and the `-wal` file. This plan
fixes each of those, mostly by deleting hand-rolled copies in favour of the
one existing `KeychainItem` type.

## Current state

All excerpts are from commit `8165d29`.

### Files

- `App/Models/KeychainItem.swift` — the one shared generic-password type.
  `load() -> LoadResult` (`.data(Data)`, `.missing`, `.failed(OSStatus)`,
  lines 24-28), `save(_:) -> Bool` (124-132), `delete() -> Bool` (137-150,
  deletes from both the data-protection and the file keychain and treats
  `errSecItemNotFound` as success). NOT modified by this plan.
- `App/Services/Location/FindMyPeopleBootstrap.swift` — the app half of setup;
  owns three private hand-rolled keychain functions.
- `App/Services/Location/LocalStoragePeopleProvider.swift` — decrypts Apple's
  `LocalStorage.db` plus `-wal` in memory; `parseWAL` at 381-424.
- `App/Services/Location/LocalStorageKeyStorage.swift` — Keychain items for
  the database key and identity secret; caches one deadline reader.
- `App/Services/Location/LocationHistoryStore.swift` — actor over
  `location-history.sqlite`; the two user-initiated deletes at 362-379.
- `App/Controllers/PairedClientStorage.swift`,
  `App/Services/Location/ICloudCredentialStorage.swift` — each declares its
  own copy of `KeychainItem.LoadResult` plus a mapper. Owned by other plans;
  this plan touches them ONLY for the enum swap in Step 1.
- `App/Views/SettingsView.swift` — `FindMyPeopleSettingsSection`, lines
  ~590-766.
- `Scripts/find-my-people-bootstrap.sh`, `Scripts/verify-find-my-people-security.sh`,
  `Scripts/find_my_people_key.py`, `Scripts/observe-find-my-people.sh` —
  human-run setup scripts (edit text only).
- `docs/find-my-people-setup.md` — the owner-facing procedure.

### A1. Four copies of one enum

`App/Models/KeychainItem.swift:24-28`:

```swift
    enum LoadResult: Equatable {
        case data(Data)
        case missing
        case failed(OSStatus)
    }
```

Identical shapes: `PairedClientStorage.KeychainLoadResult`
(`App/Controllers/PairedClientStorage.swift:12-16`),
`ICloudCredentialStorage.RawLoadResult`
(`App/Services/Location/ICloudCredentialStorage.swift:106-110`),
`LocalStorageKeyStorage.RawLoadResult`
(`App/Services/Location/LocalStorageKeyStorage.swift:44-48`). Each has an
identity mapper, e.g. `LocalStorageKeyStorage.swift:222-228`:

```swift
    private static func keychainLoad(service: String) -> RawLoadResult {
        switch keychainItem(service: service).load() {
        case .data(let data): .data(data)
        case .missing: .missing
        case .failed(let status): .failed(status)
        }
    }
```

(same at `PairedClientStorage.swift:273-279` and
`ICloudCredentialStorage.swift:314-320`). No test names any of the three
nested enums (`grep -rn "KeychainLoadResult\|RawLoadResult" iMCPTests CLITests`
is empty); tests only write `.data(...)`, `.missing`, `.failed(...)`.

### A2. Bootstrap keychain: delete does not match save, results ignored

`FindMyPeopleBootstrap.swift:435-450` (load) and `452-470` (save) both set
`kSecAttrAccount: "state"`, `kSecAttrSynchronizable: false` and
`kSecUseDataProtectionKeychain: true`. The delete does not, and discards the
status (`482-490`):

```swift
    private static func clearPreparedStateAndKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: stateService,
            kSecAttrAccount as String: "state",
        ]
        SecItemDelete(query as CFDictionary)
        deletePrivateKey()
    }
```

`deletePrivateKey()` (`401-408`) also discards its `SecItemDelete` status.
`state()` (`165-173`) reports `.handoffReady` whenever the prepared state can
still be loaded, so a failed delete leaves "Cancel Setup" apparently doing
nothing. Whether an unflagged `SecItemDelete` reaches a data-protection item
is an implementation detail of Security.framework; the code must not depend
on it.

`prepare()` clears before creating (`:189`), and `createOneTimeKey()` deletes
the old RSA key again (`:369`); if that delete fails, a second key with the
same tag is created and `loadPrivateKey()` (`388-399`) may return the old one,
so the eventual import fails with `.importFailed` after the owner has already
been through Recovery.

The three hand-rolled functions are data-protection-only: an unentitled build
gets `.keychainUnavailable`. That was not a design decision — `KeychainItem`
was introduced later (commit `cba2d0e`) to replace three such copies and this
fourth was simply not migrated; the RSA private key in the same file already
lives in the file keychain (no `kSecUseDataProtectionKeychain` at `370-379`).
Existing items were saved to the data-protection keychain with account
`"state"`; `KeychainItem(service:account:)` reads exactly those.

Lead dropped: `:398` `return (item as! SecKey)`. A conditional cast to a
CoreFoundation type always succeeds and `as?` does not compile cleanly under
warnings-as-errors; the force cast is the standard idiom. Leave it.

### A3. WAL parser throws where SQLite stops

`LocalStoragePeopleProvider.swift:401-417`, inside
`for index in 0 ..< completeFrames`:

```swift
            guard pageNumber > 0,
                readBE32(data, at: offset + 8) == salt1,
                readBE32(data, at: offset + 12) == salt2
            else { throw LocalStoragePeopleError.malformedDatabase }
            ...
            guard checksum.0 == readBE32(data, at: offset + 16),
                checksum.1 == readBE32(data, at: offset + 20)
            else { throw LocalStoragePeopleError.malformedDatabase }
```

After a WAL restart SQLite rewrites the header salts and overwrites frames
from the start; older frames past the new end keep the old salts. SQLite's
own recovery stops at the first frame whose page number is 0, whose salts do
not match the header, or whose cumulative checksum is wrong, and uses
everything up to the last valid commit frame. Throwing here turns a normal
file state into "malformed database". The code after the loop (`419-423`)
already keeps only frames up to `lastCommit`, so stopping the loop is enough.

Existing test that encodes the wrong behaviour,
`iMCPTests/LocalStoragePeopleProviderTests.swift:188-192`:

```swift
    func testWALRejectsBadChecksumTornTailAndOutOfRangePage() throws {
        let body = Data(repeating: 0xA5, count: pageSize)
        var badChecksum = makeWAL(pages: [(0, body)], committedPageCount: 1)
        badChecksum[60] ^= 0x01
        XCTAssertThrowsError(try LocalStoragePeopleProvider.parseWAL(badChecksum))
```

(byte 60 is inside frame 0's page body: header 32 + frame header 24 = 56.)
The fixture builder `makeWAL(pages:committedPageCount:)` is at `:346-371` of
the same file; frame size is `24 + 4096`.

### A4. A transient Keychain failure is cached until relaunch

`LocalStorageKeyStorage.swift:78-88`:

```swift
        func load(within deadline: Duration) async -> LocalStorageSecretLoadResult {
            let reader = readerLock.withLock {
                if let reader = self.reader { return reader }
                let reader = DeadlinedValue<LocalStorageSecretLoadResult> { [weak self] in
                    self?.load() ?? .unavailable
                }
                self.reader = reader
                return reader
            }
            return await reader.value(within: deadline) ?? .unavailable
        }
```

`DeadlinedValue` (`App/Models/DeadlinedValue.swift`, an `actor`) runs its read
at most once and returns `nil` from `value(within:)` when the deadline arrives
first. The cached reader is dropped only by a successful `save`/`delete`
(`90-104`). So one `.unavailable` (Keychain locked right after login) or
`.missing` result is served forever. The coalescing of a still-blocked read is
deliberate and tested
(`iMCPTests/ICloudAuthPlumbingTests.swift`,
`testDeadlineReadsCoalesceAndSuccessfulMutationInvalidatesTheResult`); only a
*finished, non-success* result must not be kept.

### A5. Deleted location history stays on disk

`LocationHistoryStore.swift:362-379`:

```swift
    func deleteSamples() throws {
        let db = try connection()
        guard sqlite3_exec(db, "DELETE FROM samples", nil, nil, nil) == SQLITE_OK else {
            throw unavailable(db)
        }
    }

    func deletePeopleSamples() throws {
        let db = try connection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM samples WHERE provider = ?", -1, &statement, nil) == SQLITE_OK
        else {
            throw unavailable(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, LocationSampleProvider.people, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw unavailable(db) }
    }
```

`migrate` runs on every open and starts with (`:574-576`):

```swift
        let initialStatements = [
            "PRAGMA journal_mode = WAL",
            "PRAGMA temp_store = MEMORY",
```

There is no `secure_delete` and no checkpoint, so deleted coordinates remain
in free pages of the main file and in `location-history.sqlite-wal`. Callers
of the two deletes are the Settings alerts (`App/Views/SettingsView.swift:706`,
`:834`, `:851`).

### A6. "Clear Key" is one click; "Cancel Setup" ignores failure

`App/Views/SettingsView.swift:645-674` (inside `switch bootstrapState`):

```swift
                    case .handoffReady, .restorationRequired:
                        Button("Show Setup Folder") { showSetupFolder() }
                        Button("Cancel Setup", role: .destructive) {
                            Task {
                                await FindMyPeopleBootstrap.shared.clearPreparedHandoff()
                                await refresh()
                            }
                        }
                    case .envelopeReady:
                        ...
                        Button("Cancel Setup", role: .destructive) {
                            Task {
                                await FindMyPeopleBootstrap.shared.clearPreparedHandoff()
                                await refresh()
                            }
                        }
                    case .configured:
                        Button("Clear Key", role: .destructive) {
                            Task {
                                _ = await FindMyPeopleReadiness.shared.clearDatabaseKey()
                                await refresh()
                            }
                        }
                        Button("Purge People Data…", role: .destructive) {
                            showingPurgeAlert = true
                        }
```

and the alert at `:699-718`:

```swift
        .alert("Purge Find My People Data", isPresented: $showingPurgeAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Purge", role: .destructive) {
                run {
                    try await FindMyPeopleReadiness.shared.purge(
                        deletePeopleHistory: {
                            try await LocationHistoryStore.shared.deletePeopleSamples()
                        },
                        clearPreparedHandoff: {
                            await FindMyPeopleBootstrap.shared.clearPreparedHandoff()
                        }
                    )
                }
            }
        } message: {
            Text(
                "This deletes the imported key, installation identity, pending setup, and recorded friend locations. Device history and named places are kept."
            )
        }
```

Undoing "Clear Key" costs a full Recovery / SIP / reboot cycle, yet it has no
confirmation and discards the `Bool` result. The audit lead proposed deleting
the button because "Purge covers it". That is refuted: Purge also deletes the
identity secret (which changes every friend's opaque identifier) and all
friend history, and "Clear Key" is the only path from `.configured` back to
"Prepare Setup" for a key re-capture (`docs/find-my-people-setup.md:8-9,106`).
Keep the action; route it through the existing alert instead.

The view's helper (`:737-751`) already does what both buttons need:

```swift
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        working = true
        message = nil
        Task { @MainActor in
            do {
                try await operation()
            } catch let error as ClientFacingError {
                message = error.errorDescription
            } catch {
                message = "The Find My People setup action could not be completed."
            }
            working = false
            await refresh()
        }
    }
```

### B1. Verifier is not fail-closed

`Scripts/verify-find-my-people-security.sh:34-54`:

```bash
BPUTIL_OUTPUT="$(/usr/bin/bputil -d 2>&1)"
if grep -Eiq 'Full Security|security mode[^[:alnum:]]+full' <<<"${BPUTIL_OUTPUT}"; then
  FULL_SECURITY=true
else
  echo "could not prove Full Security" >&2
  exit 1
fi

SIP_OUTPUT="$(/usr/bin/csrutil status 2>&1)"
ROOT_OUTPUT="$(/usr/bin/csrutil authenticated-root status 2>&1)"
grep -Eiq 'status: enabled' <<<"${SIP_OUTPUT}" || { echo "SIP is not fully enabled" >&2; exit 1; }
grep -Eiq 'status: enabled' <<<"${ROOT_OUTPUT}" || { echo "authenticated root is not enabled" >&2; exit 1; }

BOOT_ARGS="$(/usr/sbin/nvram boot-args 2>/dev/null || true)"
if grep -Eiq 'amfi_get_out_of_my_way|amfi_allow_any_signature|cs_enforcement_disable|task_for_pid-allow|kext-dev-mode|(^|[[:space:]])debug($|[=[:space:]])' <<<"${BOOT_ARGS}"; then
  echo "a debugger, AMFI, code-signing, or kernel weakening boot argument is present" >&2
  exit 1
fi

DEVELOPER_OUTPUT="$(/usr/sbin/DevToolsSecurity -status 2>&1)"
if grep -Eiq 'enabled' <<<"${DEVELOPER_OUTPUT}"; then DEVELOPER=true; else DEVELOPER=false; fi
```

Problems: (a) any text containing "Full Security" — including a warning or
usage message on stderr — proves Full Security; (b) `status: enabled` is a
substring, so a customised SIP configuration whose first line still contains
it passes; (c) a failed `nvram` read is indistinguishable from "no boot
arguments"; (d) boot arguments are checked against a six-entry blocklist; (e)
`DevToolsSecurity` output that says neither enabled nor disabled is recorded
as `false`. The report writer (`:138-145`) hard-codes
`"sipEnabled": True, "authenticatedRootEnabled": True, "unsafeBootArguments": []`,
which is only honest if the shell above exits on anything else.

### B2. Capture wrapper cannot stop its own root debugger

`Scripts/find-my-people-bootstrap.sh:72-134` runs an unprivileged Python
wrapper that itself launches `sudo lldb`:

```bash
  capture)
    preflight
    PID="$(/usr/bin/pgrep -x findmylocateagent)"
    /usr/bin/python3 - "${PID}" "${ROOT}/Scripts/find_my_people_key.py" "${HANDOFF}" "${ENVELOPE}" \
      "${CAPTURE_TIMEOUT_SECONDS}" <<'PY'
...
command = [
    "/usr/bin/sudo",
    "/usr/bin/lldb",
...
process = subprocess.Popen(command, preexec_fn=os.setpgrp)
...
finally:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
sys.exit(status)
```

`os.setpgrp` moves `sudo lldb` out of the terminal's foreground process
group: the terminal's Ctrl-C never reaches it, a password prompt from a
background group can stall, and `os.killpg` from an unprivileged process on a
root-owned group raises `PermissionError` inside `finally` — leaving a root
LLDB attached to Apple's agent with the breakpoint armed, on a Mac whose
security is currently weakened.

### B3. Smaller script defects

- `find-my-people-bootstrap.sh:38` — `PIDS=($(/usr/bin/pgrep -x findmylocateagent))`.
  Under `set -e` a `pgrep` with no match exits 1 and the script dies silently
  before the helpful message on `:39`. `:74` then queries the PID a second
  time, after it was validated.
- `:51-54` — `--dry-run` only runs the verifier's dry-run (six system tools),
  although `docs/find-my-people-setup.md:14` says "Do not continue unless
  `Scripts/find-my-people-bootstrap.sh --dry-run` passes." LLDB and OpenSSL
  are never checked, and the message claims prerequisites are "inspected only
  when a prepared handoff exists", which nothing does.
- `:66-69` and `:145-148` — `baseline` refuses when `baseline.json` exists and
  says "remove or archive the old baseline first", but no mode removes it;
  `cleanup` skips it and skips the orphaned temporaries
  `.envelope-*.tmp` (`find_my_people_key.py:146`) and `.baseline.json-*.tmp`
  / `.restoration.json-*.tmp` (`verify-find-my-people-security.sh:159`).
- `Scripts/find_my_people_key.py:220` — `key = b"\0" * 32` rebinds a local
  name; it wipes nothing and reads as if it did.
- `Scripts/observe-find-my-people.sh:9` —
  `DARWIN_DIR="$(getconf DARWIN_USER_DIR 2>/dev/null || true)"`; on failure
  the confinement path becomes a relative path and every row is all zeros.
  `:13-26` `metadata()` also prints all zeros when the container is
  TCC-denied, identical to "file absent".

### Conventions that apply

- Swift 6 strict concurrency; warnings are errors; deployment target macOS
  15.1. Local Xcode is 27 beta and additionally fails on `ImplicitStrongCapture`
  (write `[weak self]`/`[self]` explicitly in escaping closures) and
  `NoUseUnstructuredThrowingTask`.
- All members of a SwiftUI `View` are `@MainActor`-isolated.
- Errors reach the user only through types conforming to `ClientFacingError`
  (`App/Controllers/ToolErrorResponse.swift`).
- `AGENTS.md:92-102` (binding): "Bootstrap is human-gated: agents and app code
  must not enter Recovery, change SIP/AMFI/boot policy, reboot, attach LLDB,
  or enter a password." and "`verify-find-my-people-security.sh` fails closed
  on incomplete posture evidence; `observe-find-my-people.sh` must remain
  blind to names, coordinates, identifiers, keys, SQL, and absolute user
  paths."
- Owner preference (binding): improve by deletion and consolidation. Do not
  add new types, protocols, or helper files.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| One test class | `Scripts/test.sh --only iMCPTests/<TestClass>` | all pass |
| App suite | `Scripts/test.sh --app-only` | all pass |
| Both suites | `Scripts/test.sh` | all pass |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |
| Shell syntax (the ONLY thing you may do with a Find My People `.sh`) | `bash -n Scripts/<name>.sh` | exit 0, no output |
| Python syntax (the ONLY thing you may do with `find_my_people_key.py`) | `python3 -m py_compile Scripts/find_my_people_key.py` | exit 0 |

`Scripts/test.sh` is the general test runner, not a Find My People script; it
is allowed. `--only SPEC` passes `-only-testing:SPEC` and implies
`--app-only`. Never run `xcodebuild test -scheme iMCP` directly (the always-on
watchdog relaunches the installed app and breaks the test host) and never
`launchctl bootout` the always-on agent. Do not run `Scripts/install-local.sh`.
`bash -n` does not check the Python heredocs inside the shell scripts; see
Step 8 for how to syntax-check those without executing them.

## Scope

**In scope** (the only files you should modify):

- `App/Services/Location/FindMyPeopleBootstrap.swift`
- `App/Services/Location/LocalStoragePeopleProvider.swift`
- `App/Services/Location/LocalStorageKeyStorage.swift`
- `App/Services/Location/LocationHistoryStore.swift`
- `App/Views/SettingsView.swift` — only `FindMyPeopleSettingsSection`
  (the `switch bootstrapState` buttons and the purge alert)
- `App/Controllers/PairedClientStorage.swift` — enum swap only (Step 1)
- `App/Services/Location/ICloudCredentialStorage.swift` — enum swap only (Step 1)
- `iMCPTests/LocalStoragePeopleProviderTests.swift`
- `iMCPTests/ICloudAuthPlumbingTests.swift` (class `LocalStorageKeyStorageTests`)
- `iMCPTests/ICloudAuthFlowTests.swift` (class `LocationHistoryStoreTests`)
- `Scripts/find-my-people-bootstrap.sh`
- `Scripts/verify-find-my-people-security.sh`
- `Scripts/find_my_people_key.py`
- `Scripts/observe-find-my-people.sh`
- `docs/find-my-people-setup.md`

**Out of scope** (do NOT touch, even though they look related):

- `App/Models/KeychainItem.swift` — used as-is; its legacy file-keychain
  adoption is noted by plan 043 and is not changed here.
- `App/Models/DeadlinedValue.swift` — its run-once contract is relied on by
  the CLI-side lesson it documents; the fix belongs in the caller.
- `Scripts/find-my-people-key.py` (dash, 12-line shim) — deleted by plan 051.
- Other `Scripts/*` — plan 050.
- The Location History alerts in `SettingsView.swift` (`:826-862`) — plan 047.
  Duplicate "Cancel Setup" buttons, the "Status" button label, the Setup Guide
  URL — plan 048.
- `FindMyPeopleReadiness.purge` signature and its tests.
- `LocationHistoryStore.deletePlace(named:)` and the retention `prune`.
- The RSA key's keychain (file vs data-protection) and the format of any
  setup artifact (`handoff.json`, `envelope.json`, `baseline.json`,
  `restoration.json`). The Swift decoder and the scripts must keep agreeing.
- No new test file (test files need four hand-made `project.pbxproj` entries;
  every test in this plan goes into an existing file).

## Git workflow

- Start from an up-to-date `main` that contains PR #61
  (`feat/menu-bar-resilience`, commits `887575d` and `8165d29`). If `main`
  does not contain `8165d29`, STOP.
- Branch: `advisor/046-find-my-people-hardening`
- One commit per step. Conventional commits, matching the repo, e.g.
  `fix: bring Settings forward from the menu; stay quiet on relaunch`,
  `feat(messages): add conversations, attachments, and chatId to messages_fetch`.
  Suggested subjects are given per step.
- Do NOT push or open a PR unless the operator instructed it. `origin`
  (`cyberpapiii/iMCP`) is the only writable remote; `upstream`
  (`mattt/iMCP`) must never receive pushes or PRs.

## Steps

### Part A — app code (agent-executable, unit-tested)

### Step 1: Use `KeychainItem.LoadResult` everywhere; delete three enums and three mappers

In each of the three files, delete the nested enum, replace every use of its
name with `KeychainItem.LoadResult`, and make the private `keychainLoad`
return the item's result directly.

- `App/Controllers/PairedClientStorage.swift`: delete
  `enum KeychainLoadResult` (`:12-16`); replace the 6 remaining
  `KeychainLoadResult` uses; `keychainLoad()` (`:273-279`) becomes
  `KeychainItem(service: keychainService).load()`.
- `App/Services/Location/ICloudCredentialStorage.swift`: delete
  `enum RawLoadResult` (`:106-110`); replace the remaining `RawLoadResult`
  uses; `keychainLoad(service:)` (`:314-320`) becomes
  `KeychainItem(service: service).load()`. Do NOT touch the separate
  `enum LoadResult` at `:98-104` (cases `.missing/.credentials/.unavailable`);
  always write the fully qualified `KeychainItem.LoadResult` in this file so
  the two cannot be confused.
- `App/Services/Location/LocalStorageKeyStorage.swift`: delete
  `enum RawLoadResult` (`:44-48`); replace the remaining uses;
  `keychainLoad(service:)` (`:222-228`) becomes
  `keychainItem(service: service).load()`.

No behaviour changes. Do not edit anything else in these files in this step.

**Verify**:
`grep -rn "KeychainLoadResult\|RawLoadResult" App iMCPTests CLITests` → no
output. Build command → exit 0.
`Scripts/test.sh --app-only` → all pass.

Commit: `refactor: use KeychainItem.LoadResult instead of three copies`

### Step 2: Bootstrap state goes through `KeychainItem`; deletes report failure

In `App/Services/Location/FindMyPeopleBootstrap.swift`:

1. Replace the two service-name constants (`:106-107`) with two items:

   ```swift
   private static let stateItem = KeychainItem(
       service: "co.dododo.iMCP.find-my-people-bootstrap-state", account: "state")
   private static let installationItem = KeychainItem(
       service: "co.dododo.iMCP.find-my-people-bootstrap-installation", account: "state")
   ```

   The service strings and the account `"state"` must be byte-identical to
   today's, or an in-progress setup is orphaned.
2. Delete `private enum KeychainLoad` (`:433`), `keychainLoad(service:)`
   (`:435-450`) and `keychainSave(_:service:)` (`:452-470`).
3. `installationBinding()` (`:415-431`): switch on `installationItem.load()`;
   `.failed` throws `.keychainUnavailable` (replaces `case .unavailable`);
   save with `installationItem.save(data)`.
4. `savePreparedState` → `stateItem.save(data)`; `loadPreparedState` →
   `guard case .data(let data) = stateItem.load() else { return nil }`.
5. `deletePrivateKey()` returns `Bool`:
   `let status = SecItemDelete(query as CFDictionary); return status == errSecSuccess || status == errSecItemNotFound`.
6. `clearPreparedStateAndKey()` becomes:

   ```swift
   @discardableResult
   private static func clearPreparedStateAndKey() -> Bool {
       let stateCleared = stateItem.delete()
       let keyCleared = deletePrivateKey()
       return stateCleared && keyCleared
   }
   ```

   Both deletes must run even when the first fails (do not write
   `stateItem.delete() && deletePrivateKey()`).
7. `createOneTimeKey()` (`:368-369`): replace the bare `deletePrivateKey()`
   with `guard deletePrivateKey() else { throw FindMyPeopleBootstrapError.keyGenerationFailed }`.
8. `prepare()`: delete line `:189` (`Self.clearPreparedStateAndKey()`); it is
   redundant — `createOneTimeKey()` deletes the old key and
   `savePreparedState` overwrites the old state. Keep the two error-path
   calls at `:201` and `:215`.
9. `clearPreparedHandoff()` (`:265-270`) becomes throwing: remove the files
   first (unchanged loop), then
   `guard Self.clearPreparedStateAndKey() else { throw FindMyPeopleBootstrapError.keychainUnavailable }`.
   Leave the call inside `importPreparedEnvelope()` (`:259`) as a discarded
   result: after a successful import `state()` returns `.configured` first.

In `App/Views/SettingsView.swift`, update the three callers:

- Both "Cancel Setup" buttons (`:649-654`, `:659-664`) become
  `Button("Cancel Setup", role: .destructive) { run { try await FindMyPeopleBootstrap.shared.clearPreparedHandoff() } }`
  (`run` already sets `working`, shows the error, and refreshes).
- In the purge alert (`:708-710`) the closure is non-throwing by signature:
  `clearPreparedHandoff: { try? await FindMyPeopleBootstrap.shared.clearPreparedHandoff() }`.
  A failure there stays visible because the section then shows
  "Handoff ready" with a working "Cancel Setup".

**Verify**:
`grep -n "kSecClassGenericPassword\|kSecUseDataProtectionKeychain" App/Services/Location/FindMyPeopleBootstrap.swift`
→ no output.
`grep -c "SecItemDelete" App/Services/Location/FindMyPeopleBootstrap.swift` → `1`.
Build → exit 0.
`Scripts/test.sh --only iMCPTests/FindMyPeopleBootstrapTests` → all pass
(4 existing tests; they cover payload and posture logic and must be
unchanged).

Commit: `fix(location): clear Find My People setup state through KeychainItem and report failure`

### Step 3: WAL replay stops at the first invalid frame instead of throwing

In `App/Services/Location/LocalStoragePeopleProvider.swift`, inside the
`for index in 0 ..< completeFrames` loop of `parseWAL` (`:398-418`), change
both `else { throw LocalStoragePeopleError.malformedDatabase }` to
`else { break }` — the page-number/salt guard (`:401-404`) and the frame
checksum guard (`:410-412`). Nothing else in the function changes: the header
checks before the loop (`:385-394`) keep throwing, and the code after the
loop already discards frames after the last commit. Add one comment above the
loop:

```swift
        // SQLite recovery stops at the first frame with a zero page number,
        // stale salts, or a bad cumulative checksum; frames left over from
        // before a WAL restart are normal, not corruption.
```

In `iMCPTests/LocalStoragePeopleProviderTests.swift`:

- In `testWALRejectsBadChecksumTornTailAndOutOfRangePage` (`:188-192`) replace
  the `XCTAssertThrowsError` line with
  `XCTAssertTrue(try LocalStoragePeopleProvider.parseWAL(badChecksum).pages.isEmpty)`
  and rename the test `testWALIgnoresBadChecksumTornTailAndKeepsOutOfRangePage`.
- Add `testWALReplayStopsAtFirstStaleOrCorruptFrame` next to it, using the
  existing `makeWAL` helper:

  ```swift
  func testWALReplayStopsAtFirstStaleOrCorruptFrame() throws {
      let first = Data(repeating: 0x11, count: pageSize)
      let second = Data(repeating: 0x22, count: pageSize)
      let committed = try LocalStoragePeopleProvider.parseWAL(
          makeWAL(pages: [(0, first)], committedPageCount: 1))
      let frameSize = 24 + pageSize
      let secondFrame = 32 + frameSize

      // makeWAL marks only the last frame as a commit, so build the
      // two-commit file by appending a second frame's bytes to a
      // one-frame WAL.
      var twoCommits = makeWAL(pages: [(0, first)], committedPageCount: 1)
      let tail = makeWAL(pages: [(0, first), (1, second)], committedPageCount: 2)
      twoCommits.append(tail[secondFrame...])
      XCTAssertEqual(try LocalStoragePeopleProvider.parseWAL(twoCommits).pages.count, 2)

      var staleSalt = twoCommits
      staleSalt[secondFrame + 8] ^= 0xFF
      XCTAssertEqual(try LocalStoragePeopleProvider.parseWAL(staleSalt), committed)

      var badChecksum = twoCommits
      badChecksum[secondFrame + 24] ^= 0x01
      XCTAssertEqual(try LocalStoragePeopleProvider.parseWAL(badChecksum), committed)

      var zeroPage = twoCommits
      zeroPage.replaceSubrange(secondFrame ..< secondFrame + 4, with: Data(count: 4))
      XCTAssertEqual(try LocalStoragePeopleProvider.parseWAL(zeroPage), committed)
  }
  ```

  (`WALReplay` is `Equatable`. The appended second frame has a valid
  cumulative checksum because `makeWAL` chains checksums and both fixtures
  share the same header and first frame.)

**Verify**: `Scripts/test.sh --only iMCPTests/LocalStoragePeopleProviderTests`
→ all pass, including the new test. Before the source change the new test
fails with a thrown `malformedDatabase`; if it passes without the source
change, STOP.

Commit: `fix(location): stop WAL replay at the first stale frame like SQLite does`

### Step 4: Do not cache a finished non-success Keychain read

In `App/Services/Location/LocalStorageKeyStorage.swift`, replace the last
line of `Store.load(within:)` (`:87`) so the function ends:

```swift
            // Still blocked: keep the reader so later callers share the one
            // pending read instead of starting more.
            guard let result = await reader.value(within: deadline) else { return .unavailable }
            if case .data = result { return result }
            // Finished without a key (locked Keychain at login, or not set
            // up yet): forget it so the next call reads again.
            readerLock.withLock { if self.reader === reader { self.reader = nil } }
            return result
```

`DeadlinedValue` is an actor, so `===` is available. Do not change
`DeadlinedValue`, `invalidateReader`, `save`, or `delete`.

Add to `LocalStorageKeyStorageTests` in
`iMCPTests/ICloudAuthPlumbingTests.swift`, modelled on
`testDeadlineReadsCoalesceAndSuccessfulMutationInvalidatesTheResult` in the
same class (it shows `CounterBox`, `DataBox`, and the six-closure initializer):

- `testTransientUnavailableDeadlineReadIsNotCached`: `databaseKeyLoad`
  increments a `CounterBox` and returns `.failed(errSecInteractionNotAllowed)`
  on the first call and `.data(key)` afterwards. Assert
  `await store.databaseKey(within: .seconds(2))` is `.unavailable`, then a
  second call is `.data(key)`, a third call is `.data(key)`, and the counter
  is `2` (success is cached).
- `testMissingDeadlineReadIsNotCached`: load returns `.missing` until a
  `DataBox` is set directly (not through `save`); assert `.missing` then
  `.data`.

**Verify**: `Scripts/test.sh --only iMCPTests/LocalStorageKeyStorageTests`
→ all pass, including the existing coalescing test unchanged (its counter
must still be `3`).

Commit: `fix(location): re-read the Find My People key after a transient Keychain failure`

### Step 5: Deleted location history is overwritten and flushed from the WAL

In `App/Services/Location/LocationHistoryStore.swift`:

1. In `migrate`, add `"PRAGMA secure_delete = ON",` immediately after
   `"PRAGMA journal_mode = WAL",` (`:575`). It is a per-connection setting and
   `migrate` runs on every open.
2. `deleteSamples()` (`:364`): change the SQL string to
   `"DELETE FROM samples; PRAGMA wal_checkpoint(TRUNCATE)"`
   (`sqlite3_exec` runs both statements).
3. `deletePeopleSamples()`: after the `sqlite3_step` guard (`:378`) add

   ```swift
           guard sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK else {
               throw unavailable(db)
           }
   ```

   The prepared statement must be finalized before the checkpoint can
   truncate; the existing `defer { sqlite3_finalize(statement) }` runs too
   late for that. Replace the `defer` with an explicit
   `sqlite3_finalize(statement)` on both exits: capture
   `let stepped = sqlite3_step(statement)`, call `sqlite3_finalize(statement)`,
   then `guard stepped == SQLITE_DONE else { throw unavailable(db) }`, then
   the checkpoint.

Add to `LocationHistoryStoreTests` in `iMCPTests/ICloudAuthFlowTests.swift`
(class starts at `:1537`; model on `testRecordingTheSameCachedFixTwiceStoresItOnce`
at `:1577` and use the class's `sample(device:latitude:longitude:secondsFromNow:)`
helper):

- `testDeletingHistoryLeavesNoRecoverableRowsOnDisk`: record
  `sample(device: "SECURE-DELETE-MARKER-7F3A", secondsFromNow: 0)`, call
  `try await store.deleteSamples()`, then read
  `directory.appendingPathComponent("history.sqlite")` and the same path with
  `-wal` appended as raw `Data`. Assert the main file does not contain
  `Data("SECURE-DELETE-MARKER-7F3A".utf8)` (`data.range(of:) == nil`) and the
  `-wal` file is absent or has size 0.
- `testDeletingPeopleHistoryTruncatesTheWAL`: record a sample, call
  `try await store.deletePeopleSamples()`, assert the `-wal` file is absent or
  has size 0.

**Verify**: `Scripts/test.sh --only iMCPTests/LocationHistoryStoreTests`
→ all pass. The first new test must fail before the source change (marker
still present); if it passes without the source change, STOP.

Commit: `fix(location): overwrite deleted location history and truncate the WAL`

### Step 6: Put "Clear Key" behind the existing confirmation

In `App/Views/SettingsView.swift`, `FindMyPeopleSettingsSection`:

1. Replace the two buttons in `case .configured:` (`:665-674`) with one:

   ```swift
                       case .configured:
                           Button("Remove…", role: .destructive) {
                               showingPurgeAlert = true
                           }
   ```

2. Change the alert (`:699-718`) to offer both removals. Keep the existing
   purge `run { ... }` body exactly as Step 2 left it:

   ```swift
           .alert("Remove Find My People Data", isPresented: $showingPurgeAlert) {
               Button("Cancel", role: .cancel) {}
               Button("Clear Key Only", role: .destructive) {
                   run {
                       guard await FindMyPeopleReadiness.shared.clearDatabaseKey() else {
                           throw FindMyPeopleLifecycleError.secretPurgeFailed(
                               databaseKeyCleared: false, identitySecretCleared: true)
                       }
                   }
               }
               Button("Purge Everything", role: .destructive) {
                   run { /* unchanged purge call */ }
               }
           } message: {
               Text(
                   "Clear Key Only removes the imported key and turns People off; using People again needs a new capture. Purge Everything also deletes the installation identity, pending setup, and recorded friend locations. Device history and named places are kept."
               )
           }
   ```

   `FindMyPeopleLifecycleError` is defined at
   `App/Services/Location/FindMyPeopleReadiness.swift:42-54` and is
   `ClientFacingError` ("Some Find My People secrets could not be deleted.
   People access remains off."). Do not add a new error type or a new
   `@State` property.
3. In `docs/find-my-people-setup.md`, replace the "Removal" paragraph
   (`:114-116`) with:

   > Settings → **Remove…** asks before doing either of two things. **Clear
   > Key Only** removes the imported database key and disables People; your
   > friend identifiers and recorded history are kept, and a new capture is
   > needed to read People again. **Purge Everything** additionally deletes
   > the installation identity, pending setup, and friend-history rows while
   > retaining device history and named places. Neither action changes
   > Apple's database or Find My sharing state.

**Verify**:
`grep -n '"Clear Key"' App/Views/SettingsView.swift` → no output.
`grep -c 'showingPurgeAlert' App/Views/SettingsView.swift` → `3`.
Build → exit 0. `swift format -i -r .` then
`swift format lint --strict --recursive .` → exit 0.
`Scripts/test.sh --app-only` → all pass.

Commit: `fix(settings): confirm before clearing the Find My People key`

### Part B — scripts (text edits only; you never run them)

Re-read the ABSOLUTE RULE at the top. After each step in this part your only
verification is a syntax check and `grep`. Behaviour is verified by the owner
in Step 11.

### Step 7: HUMAN STEP — owner confirms the exact posture lines (STOP and hand off)

The fail-closed patterns in Step 8 are anchored to exact tool output that no
agent may produce. Before writing Step 8, stop and ask the owner to run the
following on the Mac in its normal Full Security state and paste back ONLY
the printed lines (they contain posture facts, no identifiers or secrets):

```console
csrutil status
csrutil authenticated-root status
nvram boot-args; echo "exit=$?"
DevToolsSecurity -status
sudo bputil -d | grep -E '^(Security Mode|SIP Status|Signed System Volume Status|Boot Args Filtering Status)'
```

(The owner should not paste the full `bputil -d` output: it contains the
chip's unique identifier.)

Expected, and what Step 8's patterns assume:

| Command | Expected output |
|---|---|
| `csrutil status` | exactly one line: `System Integrity Protection status: enabled.` |
| `csrutil authenticated-root status` | exactly one line: `Authenticated Root status: enabled` (a trailing `.` is tolerated) |
| `nvram boot-args` | non-zero exit and an error containing `data was not found` (variable unset), or exit 0 with `boot-args` followed by nothing |
| `DevToolsSecurity -status` | `Developer mode is currently enabled.` or `Developer mode is currently disabled.` |
| `bputil -d` filter | a line starting `Security Mode:` whose value is `Full` |

If any line the owner pastes differs from this table (other than spacing
inside the `bputil` line), adjust ONLY the corresponding anchored pattern in
Step 8 to the owner's exact text and record the pasted line in the commit
message. If the owner reports that `boot-args` is set to something on the
healthy Mac, STOP: the verifier will (correctly, per this plan) refuse any
boot argument, and the owner must decide whether to remove it. If the owner
is unavailable, skip Step 8 (leave the verifier unchanged), continue with
Steps 9-10, and report Step 8 as BLOCKED on the human step.

### Step 8: Verifier accepts only exact, recognised posture evidence

In `Scripts/verify-find-my-people-security.sh`, replace lines `34-54` (from
`BPUTIL_OUTPUT=` through the `DEVELOPER=` line) with this shape. Keep
everything before line 34 and from `BOOT_UUID=` onward unchanged.

```bash
fail() { echo "$1" >&2; exit 1; }

# stderr is never part of the evidence, and a failed tool proves nothing.
BPUTIL_OUTPUT="$(/usr/bin/bputil -d 2>/dev/null)" || fail "bputil could not read the startup security policy"
SECURITY_MODE="$(grep -E '^Security Mode:' <<<"${BPUTIL_OUTPUT}" || true)"
[[ "${SECURITY_MODE}" =~ ^Security\ Mode:[[:space:]]+Full([[:space:]].*)?$ ]] || fail "could not prove Full Security"
FULL_SECURITY=true

SIP_OUTPUT="$(/usr/bin/csrutil status 2>/dev/null)" || fail "csrutil could not report SIP status"
[[ "${SIP_OUTPUT}" == "System Integrity Protection status: enabled." ]] || fail "SIP is not fully enabled"

ROOT_OUTPUT="$(/usr/bin/csrutil authenticated-root status 2>/dev/null)" || fail "csrutil could not report authenticated root"
[[ "${ROOT_OUTPUT}" =~ ^Authenticated\ Root\ status:\ enabled\.?$ ]] || fail "authenticated root is not enabled"

# Allowlist: the only accepted states are "variable unset" and "variable empty".
if BOOT_ARGS="$(/usr/sbin/nvram boot-args 2>&1)"; then
  [[ "${BOOT_ARGS}" =~ ^boot-args[[:space:]]*$ ]] || fail "boot arguments are set; remove every boot argument first"
else
  [[ "${BOOT_ARGS}" == *"data was not found"* ]] || fail "could not read boot arguments"
fi

DEVELOPER_OUTPUT="$(/usr/sbin/DevToolsSecurity -status 2>/dev/null)" || fail "DevToolsSecurity could not report its status"
case "${DEVELOPER_OUTPUT}" in
  "Developer mode is currently enabled.") DEVELOPER=true ;;
  "Developer mode is currently disabled.") DEVELOPER=false ;;
  *) fail "unrecognised Developer Tools Security status" ;;
esac
```

Rules that must hold in whatever you write (they matter more than the exact
lines above):

- No `2>&1` on `bputil`, `csrutil`, or `DevToolsSecurity`. The only `2>&1` is
  on `nvram`, where the error text is the evidence for "unset" and is matched
  only in the failure branch.
- No `|| true` on a posture command. (`|| true` on the `grep` that filters an
  already-captured string is fine.)
- Every comparison is a whole-string `==` or a regex anchored with `^` and
  `$`. A multi-line `SIP_OUTPUT` (a customised configuration prints extra
  lines) must therefore fail.
- If two `Security Mode:` lines exist, `SECURITY_MODE` contains a newline and
  the anchored regex fails. That is intended.
- The six-entry boot-argument blocklist regex is deleted, not kept alongside.
- Do not change the embedded Python report writer or any JSON field.

Also update `docs/find-my-people-setup.md:33-36`: replace "no known
AMFI/debug/code-signing weakening boot argument" with "no boot argument at
all".

**Verify**:
`bash -n Scripts/verify-find-my-people-security.sh` → exit 0, no output.
`grep -n 'amfi_get_out_of_my_way\|status: enabled' Scripts/verify-find-my-people-security.sh` → no output.
`grep -c '2>&1' Scripts/verify-find-my-people-security.sh` → `1`.
`grep -n '|| true' Scripts/verify-find-my-people-security.sh` → exactly one
line, the `grep -E '^Security Mode:'` filter.
Heredoc unchanged: `git diff 8165d29 -- Scripts/verify-find-my-people-security.sh | grep -c '^[-+].*json\|^[-+].*os\.'` → `0`.

Commit: `fix(scripts): make the Find My People security verifier accept only exact posture lines`

### Step 9: Capture wrapper runs where it can stop its own debugger; smaller bootstrap fixes

All in `Scripts/find-my-people-bootstrap.sh`.

1. **Dependencies in dry-run.** Move the tool loop (`:32-34`) into its own
   function placed above `preflight()`, and call it from both places:

   ```bash
   check_dependencies() {
     for tool in /usr/bin/lldb /usr/bin/openssl /usr/bin/python3 /usr/bin/pgrep /bin/ps /usr/bin/sudo; do
       [[ -x "${tool}" ]] || { echo "missing bootstrap dependency: ${tool}" >&2; exit 1; }
     done
   }
   ```

   `preflight()` starts with `check_dependencies`. The `--dry-run` case
   becomes: verifier `--dry-run` line (unchanged), `check_dependencies`, then
   `echo "dry-run: system tools and capture dependencies present; the handoff and the Apple agent are checked by 'preflight'; no attachment or mutation performed"`.
2. **Silent exit and double PID lookup.** `:38` becomes
   `PIDS=($(/usr/bin/pgrep -x findmylocateagent || true))`. Delete `:74`
   (`PID="$(...)"`) and pass `"${PIDS[0]}"` as the first argument on `:75`.
3. **Privilege moves outward.** On `:75` prefix the interpreter with sudo:
   `/usr/bin/sudo /usr/bin/python3 - "${PIDS[0]}" ...` (arguments and heredoc
   unchanged). sudo sets `SUDO_UID`/`SUDO_GID`, which
   `find_my_people_key.py:30-38` requires, and the child LLDB inherits them.
   The password prompt now happens once, in the foreground, before anything
   attaches.
4. **Inside the heredoc**:
   - delete the `"/usr/bin/sudo",` element from `command` (`:86`);
   - `:102` becomes `process = subprocess.Popen(command)` (no `preexec_fn`),
     so LLDB stays in the terminal's foreground process group and receives
     Ctrl-C directly;
   - replace the `finally:` body (`:125-132`) with an escalation the now-root
     wrapper is allowed to perform — interrupt first so LLDB's own
     `process detach` / `quit` batch commands run, then terminate, then kill:

     ```python
     finally:
         signal.signal(signal.SIGINT, signal.SIG_IGN)
         signal.signal(signal.SIGTERM, signal.SIG_IGN)
         for stop in (lambda: process.send_signal(signal.SIGINT), process.terminate, process.kill):
             if process.poll() is not None:
                 break
             stop()
             try:
                 process.wait(timeout=10)
             except subprocess.TimeoutExpired:
                 pass
     ```

   - do not remove any import: `shlex.quote` is still used on `:92-94`, and
     `os` and `signal` are still referenced. If, after your edit, an import
     is no longer referenced anywhere in the heredoc, delete that import
     only.
5. **Start over.** `cleanup` (`:145-148`) becomes:

   ```bash
     cleanup)
       rm -f "${ENVELOPE}" "${RESTORATION}" \
         "${ARTIFACT_DIR}"/.envelope-*.tmp "${ARTIFACT_DIR}"/.baseline.json-*.tmp "${ARTIFACT_DIR}"/.restoration.json-*.tmp
       if [[ "${2:-}" == "--all" ]]; then
         rm -f "${BASELINE}"
         echo "removed the recorded baseline; run 'baseline' again in Full Security before preparing setup"
       fi
       echo "removed encrypted staging artifacts; use Cancel Setup in iMCP to remove the handoff and private key"
       ;;
   ```

   Change the `baseline` refusal message (`:67`) to
   `"a baseline already exists; run '$0 cleanup --all' to start over"` and the
   usage line (`:150`) to end `...|verify-restored|cleanup [--all]`.
6. In `docs/find-my-people-setup.md`: after the sentence at `:65-66` add
   "To abandon setup entirely and record a fresh baseline later, run
   `Scripts/find-my-people-bootstrap.sh cleanup --all` after security is
   restored." At `:60-61` change "then the administrator-authorized LLDB
   session arms" to "then asks for administrator authorization once and the
   LLDB session arms".

**Verify** (never run the script):
`bash -n Scripts/find-my-people-bootstrap.sh` → exit 0, no output.
`grep -n 'setpgrp\|killpg' Scripts/find-my-people-bootstrap.sh` → no output.
`grep -c 'pgrep -x findmylocateagent' Scripts/find-my-people-bootstrap.sh` → `1`.
`grep -c '/usr/bin/sudo' Scripts/find-my-people-bootstrap.sh` → `2`
(dependency list and the interpreter prefix).
Syntax-check the heredoc WITHOUT executing it — this only parses text:
`sed -n "/<<'PY'/,/^PY\$/p" Scripts/find-my-people-bootstrap.sh | sed '1d;$d' | python3 -c 'import ast,sys; ast.parse(sys.stdin.read()); print("ok")'`
→ `ok`.

Commit: `fix(scripts): keep the Find My People debugger in the foreground and stoppable`

### Step 10: Key module and observer

1. `Scripts/find_my_people_key.py`: delete line `:220` (`key = b"\0" * 32`).
   Nothing else.
2. `Scripts/observe-find-my-people.sh`:
   - `:9` becomes

     ```bash
     DARWIN_DIR="$(getconf DARWIN_USER_DIR)"
     [[ -n "${DARWIN_DIR}" ]] || { echo "could not resolve the per-user directory" >&2; exit 1; }
     ```

   - in `metadata()` add a metadata-only flag that says whether the
     containing directory could be listed at all (a TCC denial makes it
     `false`; "file not there yet" leaves it `true`). The listing is
     discarded, so the script stays blind:

     ```bash
       local readable=false
       if /bin/ls "${path%/*}" >/dev/null 2>&1; then readable=true; fi
     ```

     and extend the `printf` to
     `'{"path_class":"%s","readable":%s,"database_size":%s,...}\n'` with
     `"${readable}"` as the second argument.
   - Do not print `${path}`, `${DARWIN_DIR}`, file names, or any file
     content.

**Verify**:
`python3 -m py_compile Scripts/find_my_people_key.py` → exit 0 (then delete
any `Scripts/__pycache__` it created: `rm -rf Scripts/__pycache__`).
`grep -n 'b"\\0"' Scripts/find_my_people_key.py` → no output.
`bash -n Scripts/observe-find-my-people.sh` → exit 0.
`grep -c '"readable"' Scripts/observe-find-my-people.sh` → `1`.
`grep -n 'echo.*\${path}\|printf.*\${path}\|DARWIN_DIR}"$' Scripts/observe-find-my-people.sh`
→ no output.

Commit: `fix(scripts): fail the Find My People observer on an unreadable source; drop a no-op wipe`

### Step 11: HUMAN STEP — owner verifies Part B (STOP and hand off)

Hand the owner this list. None of it weakens security; all of it runs on the
Mac in its normal Full Security state. Report the plan as "Part B awaiting
owner verification" until the owner confirms.

1. `Scripts/find-my-people-bootstrap.sh --dry-run` → prints the verifier's
   dry-run line and the new "system tools and capture dependencies present"
   line; exit 0.
2. `sudo Scripts/verify-find-my-people-security.sh status` → prints
   "security status: Full Security, SIP, authenticated root, and boot
   arguments passed" and the Developer Tools line; exit 0. If it fails on a
   healthy Mac, the pattern for the named fact does not match this macOS
   build: send the failing message back; do not loosen a pattern to a
   substring.
3. `Scripts/find-my-people-bootstrap.sh preflight` with Find My closed long
   enough that no `findmylocateagent` is running (or simply before preparing
   setup) → a clear message (`prepare setup in iMCP first` or
   `expected exactly one findmylocateagent`), never a silent exit.
4. `Scripts/find-my-people-bootstrap.sh cleanup --all` in a state where the
   owner is content to re-record the baseline → `baseline.json` is gone from
   `~/Library/Application Support/iMCP/FindMyPeopleBootstrap/`; then
   `Scripts/find-my-people-bootstrap.sh baseline` succeeds again.
5. `Scripts/observe-find-my-people.sh 4 2` → every row has a `"readable"`
   field; no names, coordinates, or absolute paths appear.
6. In iMCP Settings → Location → Find My People: "Prepare Setup", then
   "Cancel Setup" → status returns to "Not configured"; when configured,
   "Remove…" shows the three-button alert and Cancel does nothing.
7. Only if the owner is already performing a real capture per
   `docs/find-my-people-setup.md` (never solely to test this plan): during
   `capture`, the password prompt appears before LLDB attaches; pressing
   Ctrl-C while the breakpoint is armed ends the command within about ten
   seconds and `pgrep -x lldb` prints nothing afterwards.

## Test plan

New and changed tests, all in existing files (no `project.pbxproj` edits):

| File / class | Test | Covers |
|---|---|---|
| `iMCPTests/LocalStoragePeopleProviderTests.swift` | `testWALReplayStopsAtFirstStaleOrCorruptFrame` (new) | stale salt, bad checksum, zero page number after a valid commit → replay equals the committed prefix |
| same | `testWALIgnoresBadChecksumTornTailAndKeepsOutOfRangePage` (renamed, one assertion changed) | a WAL whose only frame is corrupt replays nothing instead of throwing |
| `iMCPTests/ICloudAuthPlumbingTests.swift` / `LocalStorageKeyStorageTests` | `testTransientUnavailableDeadlineReadIsNotCached`, `testMissingDeadlineReadIsNotCached` (new) | Step 4; success still cached |
| same | `testDeadlineReadsCoalesceAndSuccessfulMutationInvalidatesTheResult` (unchanged) | regression guard: a blocked read is still coalesced, counter stays 3 |
| `iMCPTests/ICloudAuthFlowTests.swift` / `LocationHistoryStoreTests` | `testDeletingHistoryLeavesNoRecoverableRowsOnDisk`, `testDeletingPeopleHistoryTruncatesTheWAL` (new) | Step 5 |

Structural patterns: the same-file tests named in each step.

Not unit-tested, and why: the bootstrap keychain path (Step 2) talks to the
real Keychain through static functions and has no seam; adding one would add
more code than the step removes. It is covered by the greps in Step 2, the
unchanged `FindMyPeopleBootstrapTests`, and owner check 6 in Step 11. The
scripts are covered only by syntax checks plus Step 11.

Final verification: `Scripts/test.sh` → both suites pass, including 5 new
tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] Build command exits 0
- [ ] `Scripts/test.sh` exits 0; the 5 new tests exist and pass
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `grep -rn "KeychainLoadResult\|RawLoadResult" App iMCPTests CLITests` → no matches
- [ ] `grep -n "kSecClassGenericPassword" App/Services/Location/FindMyPeopleBootstrap.swift` → no matches
- [ ] `grep -n "malformedDatabase" App/Services/Location/LocalStoragePeopleProvider.swift | wc -l` is 2 fewer than at `8165d29`
- [ ] `grep -c "secure_delete" App/Services/Location/LocationHistoryStore.swift` → `1`; `grep -c "wal_checkpoint(TRUNCATE)" App/Services/Location/LocationHistoryStore.swift` → `2`
- [ ] `grep -n '"Clear Key"' App/Views/SettingsView.swift` → no matches
- [ ] `bash -n` exits 0 for the three `.sh` files; `python3 -m py_compile Scripts/find_my_people_key.py` exits 0
- [ ] `grep -n 'setpgrp\|killpg' Scripts/find-my-people-bootstrap.sh` → no matches
- [ ] `grep -n 'status: enabled\|amfi_get_out_of_my_way' Scripts/verify-find-my-people-security.sh` → no matches (unless Step 8 is BLOCKED on Step 7)
- [ ] `git status --short` lists only in-scope files; no `Scripts/__pycache__`
- [ ] Step 11 handed to the owner; `plans/README.md` row says DONE only after
      the owner confirms, otherwise `IN PROGRESS (Part B awaiting owner verification)`

## STOP conditions

Stop and report back (do not improvise) if:

- You are about to execute any Find My People script, `bputil`, `csrutil`,
  `nvram`, `lldb`, `DevToolsSecurity`, or `sudo`, for any reason including
  "just to see the output". Ask the owner (Step 7 / Step 11) instead.
- `main` does not contain commit `8165d29`, or the "Current state" excerpts do
  not match the live code.
- Step 2: the service strings or the `"state"` account would have to change,
  or the build needs an edit to `App/Models/KeychainItem.swift`.
- Step 3 or Step 5: a new regression test passes *before* the source change.
  The test is not exercising the defect; do not proceed on a vacuous test.
- Step 5: `testDeletingHistoryLeavesNoRecoverableRowsOnDisk` still finds the
  marker after the source change. Do not weaken the assertion; report what
  remains and where (main file or `-wal`).
- Step 4: the existing coalescing test's counter changes from `3`.
- Step 7: the owner's pasted lines differ from the table in a way that is not
  a simple exact-text substitution, or `boot-args` is set on the healthy Mac.
- Step 8: making the verifier pass on the owner's Mac would require a
  substring match, `|| true` on a posture command, or merging stderr.
- Any step appears to require changing the format of `handoff.json`,
  `envelope.json`, `baseline.json`, or `restoration.json`.
- A step's verification fails twice after a reasonable fix attempt.

## Maintenance notes

- **Behaviour changes to call out in review**:
  - The verifier now rejects ANY boot argument, not six known-bad ones. An
    owner with a benign pre-existing `boot-args` must clear it before
    `baseline`.
  - In an unentitled build (CI, no provisioning profile) the bootstrap state
    and installation secret now fall back to the file keychain like every
    other iMCP secret, instead of reporting `.keychainUnavailable`. The RSA
    key already lived there.
  - `KeychainItem.load()` adopts a same-named item from the file keychain when
    the data-protection one is missing. For the bootstrap state this grants
    nothing new: the baseline it describes is already a user-writable,
    `authoritative: false` file, and import still requires device-owner
    authentication and a real decrypt of Apple's database with the key.
  - The capture wrapper (about 50 lines of Python) now runs as root so it can
    signal LLDB. It takes no input other than the five arguments the shell
    script passes.
  - `secure_delete` makes every delete in the history store (including the
    90-day prune at open) zero its pages; cost is negligible at this size.
- **Reviewer should scrutinise**: the anchored patterns in Step 8 against the
  owner's pasted lines; that the purge alert's "Purge Everything" body is
  byte-for-byte the old "Purge" body plus `try?`; that Step 2 left the
  service strings untouched.
- **Interactions**: plan 048 merges the two "Cancel Setup" buttons and fixes
  the Setup Guide URL — after this plan each button is a single
  `run { try await ... }` line, which is what 048 should merge. Plan 047
  reworks the Location History alerts that call `deleteSamples()` /
  `deletePeopleSamples()`; those calls keep their signatures. Plan 051
  deletes `Scripts/find-my-people-key.py`. Plan 052 adds `shellcheck` over
  `Scripts/*.sh`; the edits here were not shellchecked by an agent that could
  run the scripts, so expect small follow-ups there.
- **Deferred, deliberately**:
  - WAL *header* checksum mismatch still throws `malformedDatabase`; SQLite
    treats that as an empty WAL. Left strict because a bad header on a live
    Apple database has not been observed and the provider already retries on
    an inconsistent snapshot.
  - `deletePlace(named:)` is not followed by a checkpoint; a named place is
    something the user typed, not a recorded position.
  - A capture timeout enforced inside the LLDB module was considered and
    rejected: it needs cross-thread LLDB API calls nobody can test without
    weakening security.
  - Moving the one-time RSA key to the data-protection keychain.
- Do not run `Scripts/install-local.sh` as part of this plan; install only
  when the operator asks.
