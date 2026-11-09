# Plan 043: Close the gaps in connection setup, pairing, and the Debug trust store

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Start from an up-to-date `main`** (`git fetch origin && git switch main &&
> git pull --ff-only`), with plan 037 already merged.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- App/Controllers/ServerNetworkManager.swift App/Controllers/MCPConnectionManager.swift App/Controllers/ServerController.swift App/Controllers/PairedClientStorage.swift App/Views/ConnectionApprovalView.swift App/Shared/PairingCodeIssuer.swift App/Shared/ConnectionApprovalPairing.swift App/Shared/SecretFileStore.swift App/Shared/ListenerEndpointFile.swift`
> and
> `git diff --stat 7b80094..HEAD -- CLI/CLIBootstrap.swift CLI/MCPService.swift CLI/ClientKeyStore.swift CLI/main.swift`
> (`CLI/` excerpts below were taken from `origin/main` at `7b80094`; everything
> else from `8165d29`.) If an in-scope file changed, compare the "Current
> state" excerpts against the live code before proceeding. Changes made by
> plan 037 that are listed under "Expected drift from plan 037" are not a
> mismatch. Any other mismatch is a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED (step 8 moves the owner's live trust store; every other step is LOW)
- **Depends on**: plans/037-isolate-tests-from-real-state.md (hard dependency, see STOP conditions)
- **Category**: security
- **Planned at**: commit `8165d29`, 2026-10-12

## Why this matters

An approved iMCP client can read Messages, Contacts, Location and everything
else the owner has switched on, so the code that decides who gets approved is
the app's main trust boundary. This audit found that boundary weaker than its
comments claim in eight places: the setup timeout that is meant to close
unauthenticated connections never fires; there is no limit on unapproved
sessions; a connection whose signature failed still gets the normal approval
prompt; the pairing code has no failed-guess limit and is sent to a listener
found by Bonjour name alone; the client-supplied name is shown in a security dialog
unsanitised; two races can resurrect a removed session or stack two approval
windows; and the build the owner actually runs (Debug, installed by
`Scripts/install-local.sh`) keeps the paired-client list in a plain file
instead of the Keychain.

After this plan every one of those is closed, mostly by deleting code: the
`setupTask` bookkeeping, the
Debug file backend of the paired-client store, and `SecretFileStore.write`.

## Current state

### Files and roles

- `App/Controllers/ServerNetworkManager.swift` — actor that owns every
  connection's `ConnectionSession` (auth state, phase), verifies auth
  responses, and decides approval.
- `App/Controllers/MCPConnectionManager.swift` — one per accepted connection;
  runs the MCP initialize hook and calls `markConnectionApproved`.
- `App/Controllers/ServerController.swift` — `@MainActor`; owns the approval
  queue and presents the approval window.
- `App/Views/ConnectionApprovalView.swift` — the approval dialog and its
  `ConnectionApprovalWindowController`.
- `App/Shared/PairingCodeIssuer.swift` — actor issuing the one-time pairing code.
- `App/Shared/ConnectionApprovalPairing.swift` — small pure helpers shared with tests.
- `App/Controllers/PairedClientStorage.swift` — the paired-client list (the trust store).
- `App/Shared/SecretFileStore.swift` — `#if DEBUG` plain-file store.
- `App/Models/KeychainItem.swift` — the one Keychain wrapper (data-protection
  keychain first, file keychain on `errSecMissingEntitlement`). Not modified.
- `App/Shared/ListenerEndpointFile.swift` — endpoint file the app writes and the
  CLI validates (owner, mode, live pid, code signature of that pid).
- `CLI/CLIBootstrap.swift`, `CLI/MCPService.swift`, `CLI/main.swift`,
  `CLI/ClientKeyStore.swift` — the `imcp-server` CLI: argument/env parsing,
  endpoint discovery, entry point, and the client signing key.
- `App/Views/ConnectClientWindow.swift`, `README.md` — the only two places that
  tell users how to pass a pairing code. Not modified.

### 1. The setup timeout is dead code, and sessions are uncapped

`ServerNetworkManager.swift:370-378` clears `setupTask` as soon as the setup
task's body returns:

```swift
        let task = Task {
            // Deregister before returning, or the timeout below fires against
            // a setup that already finished.
            defer {
                if var session = self.sessions[connectionID] {
                    session.setupTask = nil
                    self.sessions[connectionID] = session
                }
            }
```

That body returns when `connectionManager.start` returns, and `start` returns
once the transport is connected, long before any `initialize`
(`MCPConnectionManager.swift:70-75`: "Handlers go live with the transport,
which can be before the initialize hook resolves"). The timeout at
`ServerNetworkManager.swift:428-450` then requires the field to still be set:

```swift
            if let session = self.sessions[connectionID],
                session.setupTask != nil,
                case .settingUp = session.phase
            {
                switch session.auth {
                case .verifiedUnpaired, .preAuthenticated:
                    return  // Handshake alive; approval or initialize may still lag.
                case .none, .invalidSignature:
                    break
                }
                ...
                await removeConnection(connectionID)
            }
```

Ten seconds later `setupTask` is always `nil`, so the branch never runs and a
connection that never authenticates is kept forever. `handleNewConnection`
(`:357-368`) also inserts a session for every accepted connection with no
upper bound.

`setupTask` has only two other uses, both `session.setupTask?.cancel()`
(`:182` in `stop()`, `:351` in `removeConnection`). Each runs right after
`session.manager?.stop()`, which already cancels the connection and so ends
`start`. The field can be deleted.

### 2. A failed signature still reaches the normal approval prompt

`processAuthResponse` records the failure (`:236-248`):

```swift
        else {
            session.auth = .invalidSignature
            sessions[connectionID] = session
            serverLog.notice(
                "\(AuthPreambleDiagnostics.invalidSignature) connection=\(connectionID)"
            )
            return
        }
```

but the approval closure (`:387-407`) only special-cases `.preAuthenticated`
and `.none`; an `.invalidSignature` session falls through to
`approvalHandler(connectionID, clientInfo)` and the user sees the ordinary
"Allow …?" dialog.

### 3. `processAuthResponse` writes back a stale copy after an `await`

`:225` takes a copy (`guard var session = sessions[connectionID] else { return }`),
`:259-262` suspends (`await issuer.validate(submittedCode)`), and `:269` /
`:281` store the copy (`sessions[connectionID] = session`). If the connection
was removed during the suspension, the write re-creates the session.

### 4. Pairing codes survive wrong guesses

`PairingCodeIssuer.swift:27-34`:

```swift
    func validate(_ submittedCode: String, at date: Date = Date()) -> Bool {
        guard var current = activeCode, !current.consumed else { return false }
        guard date <= current.expiresAt else { return false }
        guard Self.normalize(submittedCode) == current.code else { return false }
        current.consumed = true
        activeCode = current
        return true
    }
```

A wrong code returns `false` and leaves the active code valid for the rest of
its five minutes.

### 5. The CLI sends the pairing code to whichever listener it found

`CLI/MCPService.swift:54-58` (origin/main) passes the code to every proxy:

```swift
                let proxy = StdioProxy(
                    endpoint: plan.endpoint,
                    parameters: parameters,
                    pairingCode: pairingCode
                )
```

`plan` is a `ResolvedEndpoint` (`:13-23`), either `.loopback` (from the
endpoint file, after `ListenerEndpointFile.inspect(isTrustedProcess:
ListenerEndpointFile.isSignedIMCPProcess)`, `:168-170`) or `.bonjour` (any
unique loopback service whose instance name is `iMCP`,
`CLI/BonjourEndpointSelection.swift:58-76`). The preamble authenticates the
client to the app, not the app to the client, so on the Bonjour path the code
goes to a peer that was identified by name only.

The endpoint-file path is the stronger one, but in a Debug build its signature
check has two exceptions that anyone can satisfy
(`App/Shared/ListenerEndpointFile.swift:305-314`):

```swift
        private static func acceptsDebugIMCPSigning(_ staticCode: SecStaticCode) -> Bool {
            if satisfiesRequirement(staticCode, compiledDebugPlugLocalRequirement) {
                return true
            }
            return isAdHocIMCP(staticCode)
        }
```

An ad-hoc signature with identifier `co.dododo.iMCP`, or a certificate whose
common name is "Plug Local Signing" with no anchor, needs no secret. These
exist for builds that have no team identity (CI signs ad hoc). The owner's
installed build is team-signed, so there the exceptions only widen the check.
`ownTeamIdentifier` (`:207-224`) already reports whether this binary has a team.

### 6. The pairing code is accepted on the command line (kept, not changed)

`CLI/CLIBootstrap.swift:102-131` (origin/main) reads `--pair <code>` from
`CommandLine.arguments` as well as `IMCP_PAIR_CODE`, and
`pairingCodeResolution` (`:80-100`) plus `PairingCodeResolution` (`:29-33`)
and `emptyToNil` (`:152-155`) reconcile the two sources. The user-facing
mentions of `--pair` are `App/Views/ConnectClientWindow.swift:86-89` and
`README.md:262-270`.

An earlier draft of this plan removed the flag because process arguments can
be read by other local processes. The owner reversed that on 2026-10-12: the
flag stays, alongside `IMCP_PAIR_CODE`. Nothing in this section is changed by
this plan; it is here so you know these symbols, tests and copy are meant to
remain exactly as they are. See Out of scope and Maintenance notes.

### 7. The client-supplied name is displayed and stored verbatim

`ServerController.swift:292-296` forwards `clientInfo.name` unmodified:

```swift
                    Task { @MainActor in
                        self.showConnectionApprovalAlert(
                            connectionID: connectionID,
                            clientName: clientInfo.name,
```

It is rendered at `ConnectionApprovalView.swift:39`
(`Text("Allow \"\(clientName)\" to connect to iMCP?")`) and saved as
`PairedClient.label` by `ConnectionApprovalPairing.pairedClientIfApproved`
(`App/Shared/ConnectionApprovalPairing.swift:15-19`), which
`SettingsView.swift:545` shows. No length cap, no control-character filter.
Separately, a client paired by code is saved with the fixed label
`"Paired Client"` (`ServerNetworkManager.swift:309`), so the Clients list
cannot tell the owner which client it was.

### 8. The approval window can be shown for a request that is no longer active

`ServerController.swift:138-147`:

```swift
        Task { @MainActor [weak self] in
            guard let self, self.approvalQueue.active?.connectionID == request.connectionID else {
                return
            }

            let verifiedFingerprint = await self.networkManager.verifiedFingerprint(
                for: request.connectionID
            )

            self.approvalWindowController.showApprovalWindow(
```

The guard runs before the `await`; nothing re-checks after it.
`ConnectionApprovalWindowController.showApprovalWindow`
(`ConnectionApprovalView.swift:93-152`) then assigns `self.window = window`
without closing a window that is already up.

Related noise: when a connection drops while its prompt is showing,
`cancelApproval` (`ServerController.swift:191-198`) denies the request itself
and then calls `dismissActiveApproval()`, which is `window?.close()`
(`ConnectionApprovalView.swift:173-175`). Closing fires `windowWillClose`,
which denies a second time, and that second denial is logged at `.error`
(`ServerController.swift:222-224`, "Ignoring approval callback for inactive
connection").

### 9. Debug builds keep the trust store in a plain file

`PairedClientStorage.swift:63-101`:

```swift
    static func production() -> PairedClientStorage {
        #if DEBUG
            let load: () -> KeychainLoadResult = { fileLoad() }
            let save: (Data) -> Bool = { fileSave($0) }
        #else
            let load: () -> KeychainLoadResult = { keychainLoad() }
            let save: (Data) -> Bool = { keychainSave($0) }
        #endif
```

`fileLoad` / `fileSave` use `SecretFileStore` with the file name
`paired-clients.json` under `~/Library/Application Support/iMCP/`
(type: JSON array of paired-client fingerprints; do not open it).
`Scripts/install-local.sh` builds Debug, so this file is the owner's live
trust store.

The file backend predates `KeychainItem`. It was added in commit `e53a0b8`
because the login keychain re-prompted after every rebuild; commit `cba2d0e`
then introduced `KeychainItem`, which uses the data-protection keychain and
does not prompt. `App/App.Debug.entitlements:5-8` carries
`keychain-access-groups`, and the local install is signed with a stable Apple
Development identity whose provisioning profile authorises it. The iCloud
credential store already moved its Debug path back to the Keychain the same
way (`App/Services/Location/ICloudCredentialStorage.swift:133-150`), so the
file backend here is a leftover.

When the file backend was introduced, the Keychain item was copied to the file
and never deleted, so the Keychain may still hold an **older** list. The file
is the current one and must win during migration.

`SecretFileStore.write` (`App/Shared/SecretFileStore.swift:39-58`) creates the
directory with default permissions and sets `0600` only after an atomic write.
Its only callers are `PairedClientStorage.swift:93` and `:100`; after this
plan it has none and is deleted. `SecretFileStore.read` and `.delete` stay
(the iCloud migration uses them).

### 10. The CLI's Debug key file is created with default permissions first

`CLI/ClientKeyStore.swift:146-157`:

```swift
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try privateKey.rawRepresentation.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
```

The file holds the CLI's P-256 private signing key (raw representation; never
read or print it). It exists with the default mode until the third line runs,
and a directory this code creates is world-readable.

The CLI cannot follow the app into the data-protection keychain: it is a bare
executable with no entitlements file (`CODE_SIGN_ENTITLEMENTS` appears only
for the app at `iMCP.xcodeproj/project.pbxproj:925` and `:989`), and the file
keychain prompts after every rebuild (see the comment at
`ClientKeyStore.swift:84-90`). The `IMCP_KEY_FILE` override is also how the
owner's `plug` client keeps its paired key. So the key file stays and only its
creation is tightened.

### Expected drift from plan 037

Plan 037 lands first and edits some of the same files. These differences from
the excerpts above are expected and are not a STOP condition:

- `ServerNetworkManager.init` no longer has a default `pairedClientStorage` argument.
- `testRegisterConnectionForTesting` has lost its unused `clientName` parameter.
- `iMCPTests/ServerNetworkManagerAuthTests.swift`:
  `testPreAuthenticatedConnectionShortCircuitsApprovalHandler` has been
  rewritten or deleted. If 037 already extracted the approval decision into a
  method on `ServerNetworkManager`, reuse that method in step 2 instead of
  adding `decideApproval`, and add the `.invalidSignature` branch to it.
- `ServerController.shared` is not constructed under XCTest (this is what
  makes step 8 safe).

### Conventions that apply

- Swift 6 strict concurrency; warnings are errors. Local Xcode is 27 beta and
  rejects an implicit strong capture of `self` in a `Task` closure and an
  unstructured `Task` whose body can throw. Keep the existing spelling:
  `self.` written out inside `Task { }`, and every error caught inside the task.
- Logging uses `serverLog` (`os.Logger`). Never log a pairing code or key material.
- App tests are XCTest classes in `iMCPTests/`, CLI tests in `CLITests/`. Test
  files are **not** in a synchronized group; add tests to existing files only
  (this plan needs no new test file).
- `App/` and `CLI/` sources are synchronized groups: deleting or adding
  declarations needs no `project.pbxproj` edit.
- All members of a SwiftUI `View` are `@MainActor`-isolated.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| All tests | `Scripts/test.sh` | all pass |
| App tests only | `Scripts/test.sh --app-only` | all pass |
| CLI tests only | `Scripts/test.sh --cli-only` | all pass |
| One app test class | `Scripts/test.sh --only iMCPTests/<TestClass>` | all pass (`--only` implies app-only) |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

Never run `xcodebuild test -scheme iMCP` directly: the always-on watchdog
relaunches the installed app and breaks the test host. Never
`launchctl bootout` the always-on agent. Do not run
`Scripts/install-local.sh`; installing is the operator's decision.

## Scope

**In scope** (the only files you should modify):

- `App/Controllers/ServerNetworkManager.swift`
- `App/Controllers/MCPConnectionManager.swift` (one call site, step 5)
- `App/Controllers/ServerController.swift`
- `App/Controllers/PairedClientStorage.swift`
- `App/Views/ConnectionApprovalView.swift` (`ConnectionApprovalWindowController` only)
- `App/Shared/PairingCodeIssuer.swift`
- `App/Shared/ConnectionApprovalPairing.swift`
- `App/Shared/SecretFileStore.swift`
- `App/Shared/ListenerEndpointFile.swift` (`acceptsDebugIMCPSigning` only)
- `CLI/CLIBootstrap.swift`, `CLI/MCPService.swift`, `CLI/main.swift`, `CLI/ClientKeyStore.swift`
- Tests: `iMCPTests/ServerNetworkManagerAuthTests.swift`,
  `iMCPTests/ServerNetworkManagerGatingTests.swift` (call-site update only),
  `iMCPTests/PairingCodeIssuerTests.swift`,
  `iMCPTests/ConnectionApprovalPairingTests.swift`,
  `iMCPTests/PairedClientStoreTests.swift`, `CLITests/CLIBootstrapTests.swift`
  (additions only; delete no existing test)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):

- Do not remove or change the `--pair <code>` flag. Owner decision 2026-10-12:
  it stays alongside `IMCP_PAIR_CODE`. That covers `resolvedPairingCode`,
  `pairingCodeResolution`, `PairingCodeResolution`, `emptyToNil` and
  `validatedPairingCode` in `CLI/CLIBootstrap.swift`, the four existing
  pairing-code tests in `CLITests/CLIBootstrapTests.swift`, and the `--pair`
  copy in `App/Views/ConnectClientWindow.swift` and `README.md`.
- `CLI/StdioProxy.swift`, `CLI/MessageFrameScanner.swift`, CLI close/retry
  handling and shared framing — plan 044.
- The auth-frame wire format (`App/Shared/AuthPreamble.swift:164-186`) and any
  server-to-client authentication frame — needs a protocol version bump; deferred.
- `App/Models/KeychainItem.swift` — its file-keychain adoption (`:95-121`) is
  low risk and stays.
- The UserDefaults-to-Keychain migration `migrateUserDefaultsIfNeeded` and the
  Debug iCloud credential migration — deliberately kept (plan 051 records this).
- The `Plug Local Signing` requirement text and `Scripts/install-local.sh` — plan 050.
- The timer in `ConnectClientWindow.swift` and other Settings/menu cleanup — plan 048.
- Service on/off toggles living in UserDefaults — accepted trust boundary.
- Any system notification (`UNUserNotificationCenter`) — see Maintenance notes.

## Git workflow

- Branch: `advisor/043-connection-pairing-security`, created from up-to-date `main`.
- One commit per step. Conventional commits, matching the repo, e.g.
  `fix: bring Settings forward from the menu; stay quiet on relaunch`. Suggested
  subjects are given per step.
- Do NOT push or open a PR unless the operator instructed it. `origin`
  (`cyberpapiii/iMCP`) is the only writable remote; never push to `upstream`.

## Steps

### Step 0: Confirm the precondition

Run:

```console
git grep -n "PairedClientStorage.production()" -- App
grep -n "| 037 " plans/README.md
```

**Verify**: the `plans/README.md` row for 037 says `DONE`, and the code path
that calls `PairedClientStorage.production()` is not reached under XCTest
(plan 037 adds a single running-tests guard at the composition root; read the
call site and confirm the guard is there). If either is false, STOP: step 8
would run a migration against the owner's real Keychain from the test host.

### Step 1: Make the setup timeout real, delete `setupTask`, cap unapproved sessions

In `App/Controllers/ServerNetworkManager.swift`:

1. Delete `var setupTask: Task<Void, Never>? = nil` from `ConnectionSession`.
2. Delete both `session.setupTask?.cancel()` lines (in `stop()` and `removeConnection`).
3. In `handleNewConnection`, delete the `defer { ... }` block and its comment,
   stop binding the task (`Task {` instead of `let task = Task {`), and delete
   the two lines `session.setupTask = task` / `sessions[connectionID] = session`
   that follow it. `var session` becomes unused; write
   `sessions[connectionID] = ConnectionSession(manager: connectionManager)`.
4. Add a pure predicate and use it in the timeout task:

```swift
    /// A setup is stalled when it has produced no verified auth response and
    /// is not parked on the user's approval decision.
    static func isStalledSetup(_ session: ConnectionSession) -> Bool {
        guard case .settingUp = session.phase else { return false }
        switch session.auth {
        case .none, .invalidSignature:
            return true
        case .verifiedUnpaired, .preAuthenticated:
            return false
        }
    }
```

   The timeout body becomes:

```swift
            if let session = self.sessions[connectionID], Self.isStalledSetup(session) {
                serverLog.warning("Connection \(connectionID) setup timed out, closing it")
                await removeConnection(connectionID)
            }
```

   Keep the long comment above the timeout task; it describes exactly this rule.
5. Add the cap. Near the other stored properties:

```swift
    /// Unapproved sessions are the only ones a peer can create without the
    /// user. The CLI opens one per MCP client, so a few dozen is generous.
    static let maxUnapprovedSessions = 32

    var hasRoomForUnapprovedSession: Bool {
        sessions.values.count(where: { $0.phase != .approved }) < Self.maxUnapprovedSessions
    }
```

   and as the first statement of `handleNewConnection`:

```swift
        guard hasRoomForUnapprovedSession else {
            serverLog.warning("Refusing connection: too many unapproved sessions")
            connection.cancel()
            return
        }
```

   A refused CLI sees a close before `initialize` and retries after one second
   (`CLI/MCPService.swift`, `.connectFailed`), so a legitimate client recovers
   on its own.

**Verify**:
- `git grep -n "setupTask" -- App iMCPTests` → no matches.
- Build command → exit 0.

Commit: `fix: reap unauthenticated connections and cap unapproved sessions`

### Step 2: Deny a connection whose signature failed

In `ServerNetworkManager.swift`, move the approval closure's body into a
method so it can be tested without a socket (skip the extraction if plan 037
already did it; then only add the `.invalidSignature` branch):

```swift
    /// The initialize-time decision for one connection.
    func decideApproval(
        for connectionID: UUID,
        clientInfo: MCP.Client.Info,
        using approvalHandler: ConnectionApprovalHandler
    ) async -> Bool {
        guard let auth = sessions[connectionID]?.auth else { return false }
        switch auth {
        case .preAuthenticated:
            serverLog.info("Auto-approving pre-authenticated connection \(connectionID)")
            return true
        case .invalidSignature:
            serverLog.notice("Denying connection \(connectionID): auth response did not verify")
            return false
        case .none:
            serverLog.notice(
                "\(AuthPreambleDiagnostics.noResponseGrace) connection=\(connectionID)"
            )
        case .verifiedUnpaired:
            break
        }

        // Mark the wait, or the setup timeout tears down a connection whose
        // approval dialog is still on screen.
        markAwaitingApproval(connectionID, waiting: true)
        let approved = await approvalHandler(connectionID, clientInfo)
        markAwaitingApproval(connectionID, waiting: false)
        return approved
    }
```

The call site in `handleNewConnection` becomes:

```swift
                try await connectionManager.start { clientInfo in
                    await self.decideApproval(
                        for: connectionID,
                        clientInfo: clientInfo,
                        using: approvalHandler
                    )
                }
```

Returning `false` uses the existing denial path in
`MCPConnectionManager.swift:52-59` (the client gets the initialize error, then
the connection is removed). Do **not** call `removeConnection` from inside
`processAuthResponse`: that function is awaited inline by the transport's
receive loop.

**Verify**: build command → exit 0;
`git grep -n "case .invalidSignature" -- App/Controllers/ServerNetworkManager.swift`
shows it in `decideApproval`.

Commit: `fix: deny connections whose auth signature does not verify`

### Step 3: Stop `processAuthResponse` from resurrecting a removed session

In `processAuthResponse`, replace the local copy with direct optional-chained
writes. `sessions[id]?.auth = x` writes nothing when the key is absent.

- Replace `guard var session = sessions[connectionID] else { return }` and the
  `switch session.auth` that follows with:

```swift
        guard let currentAuth = sessions[connectionID]?.auth else { return }

        // One-shot: a second AUTH-RESPONSE must not upgrade trust mid-approval.
        guard case .none = currentAuth else {
            serverLog.debug("Ignoring duplicate auth response for \(connectionID)")
            return
        }
```

- Replace each of the four `session.auth = <value>` / `sessions[connectionID] = session`
  pairs with the single line `sessions[connectionID]?.auth = <value>`.
- Above the write that follows `await issuer.validate(submittedCode)`, keep the
  existing "Defer persist until approval" comment and add one line: `// The
  session may have been removed during the await; this then writes nothing.`

**Verify**:
- `sed -n '/func processAuthResponse/,/^    }/p' App/Controllers/ServerNetworkManager.swift | grep -c "sessions\[connectionID\] = session"` → `0`.
- Build command → exit 0.

Commit: `fix: do not re-create a removed session after pairing-code validation`

### Step 4: Burn the pairing code after three wrong guesses

In `App/Shared/PairingCodeIssuer.swift`, replace `consumed: Bool` with a
failure counter and clear the code instead of flagging it:

```swift
    static let maxFailedAttempts = 3

    private struct ActiveCode {
        let code: String
        let expiresAt: Date
        var failedAttempts = 0
    }
```

```swift
    func validate(_ submittedCode: String, at date: Date = Date()) -> Bool {
        guard var current = activeCode, date <= current.expiresAt else { return false }
        guard Self.normalize(submittedCode) == current.code else {
            current.failedAttempts += 1
            activeCode = current.failedAttempts < Self.maxFailedAttempts ? current : nil
            return false
        }
        activeCode = nil
        return true
    }
```

Update `issue` to build `ActiveCode(code: code, expiresAt: expiresAt)`, and
extend the type's doc comment with one sentence: three wrong submissions
discard the code.

**Verify**: build command → exit 0;
`git grep -n "consumed" -- App/Shared/PairingCodeIssuer.swift` → no matches.

Commit: `fix: discard the pairing code after three wrong guesses`

### Step 5: Sanitise the client name once, and use it as the pairing label

1. In `App/Shared/ConnectionApprovalPairing.swift`, next to
   `truncatedClientFingerprint`, add:

```swift
/// The name a client reports about itself. Untrusted: it is shown in the
/// approval dialog and stored as the paired client's label, so it is reduced
/// to one bounded line with no control or formatting characters.
func sanitizedClientName(_ name: String) -> String {
    let scalars = name.unicodeScalars.filter {
        !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
    }
    let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? "Unknown client" : String(cleaned.prefix(64))
}
```

   (`CharacterSet.controlCharacters` covers Unicode categories Cc and Cf, which
   includes bidirectional overrides and zero-width characters.)
2. In `ServerController.swift`, inside the approval handler closure
   (`:277-305`), compute `let clientName = sanitizedClientName(clientInfo.name)`
   before the `serverLog.debug` line, log `clientName`, and pass
   `clientName: clientName` to `showConnectionApprovalAlert`. This is the single
   point through which the name reaches the dialog and
   `ConnectionApprovalPairing.pairedClientIfApproved`.
3. In `ServerNetworkManager.swift`, change
   `func markConnectionApproved(_ id: UUID) -> Bool` to
   `func markConnectionApproved(_ id: UUID, clientName: String) -> Bool` and
   replace `label: "Paired Client"` with `label: sanitizedClientName(clientName)`.
4. In `MCPConnectionManager.swift:64`, pass the name:
   `markConnectionApproved(self.connectionID, clientName: clientInfo.name)`.
5. Update the existing test call sites
   (`git grep -n "markConnectionApproved(" -- iMCPTests`) to pass
   `clientName: "test-client"`.

**Verify**: build command → exit 0;
`git grep -n '"Paired Client"' -- App` → no matches.

Commit: `fix: sanitise the client-supplied name and label code-paired clients with it`

### Step 6: Re-check the approval request after the await; one window at a time

1. `ServerController.swift`, `scheduleApprovalPresentation`: move the
   active-request check below the `await`.

```swift
        Task { @MainActor [weak self] in
            guard let self else { return }

            let verifiedFingerprint = await self.networkManager.verifiedFingerprint(
                for: request.connectionID
            )

            // Checked after the await: the request can be answered, cancelled,
            // or superseded while the lookup is suspended.
            guard self.approvalQueue.active?.connectionID == request.connectionID else {
                return
            }

            self.approvalWindowController.showApprovalWindow(
```

   Keep the "Defer presentation by one turn" comment above the task.
2. `ConnectionApprovalView.swift`, `ConnectionApprovalWindowController`: make
   dismissal silent and reuse it when presenting.

```swift
    /// Closes the window without answering. Callers have already settled the
    /// request with the approval queue.
    func dismissActiveApproval() {
        respondedToActiveRequest = true
        closeWindow()
    }
```

   and make the first statement of `showApprovalWindow`:

```swift
        // A window still on screen belongs to a superseded request.
        dismissActiveApproval()
```

   (before the existing `respondedToActiveRequest = false`). The only other
   caller, `ServerController.cancelApproval`, already denies the request
   directly on the line after `dismissActiveApproval()`, so nothing loses its
   continuation, and the duplicate denial that produced the `.error` log at
   `ServerController.swift:223` no longer happens. Leave that log line as is.

**Verify**: build command → exit 0;
`Scripts/test.sh --only iMCPTests/ConnectionApprovalQueueTests` → all pass.

Commit: `fix: re-check the active approval after the fingerprint lookup`

### Step 7: CLI — send the pairing code on the verified path only

How the CLI obtains the code does not change: `--pair <code>` and
`IMCP_PAIR_CODE` both stay (see Out of scope). This step changes only where
the code is sent.

1. `CLI/CLIBootstrap.swift`: leave `resolvedPairingCode`,
   `pairingCodeResolution`, `PairingCodeResolution`, `emptyToNil` and
   `validatedPairingCode` untouched. Add next to
   `prefersLoopbackAfterConnectionFailure`:

```swift
    /// The pairing code is a bearer secret and the preamble does not
    /// authenticate the app to the CLI. It goes only to the listener named by
    /// the owner-only endpoint file whose pid passed the code-signature
    /// check, never to a service chosen by its Bonjour name.
    static func pairingCodeToSend(_ code: String?, resolvedViaLoopback: Bool) -> String? {
        resolvedViaLoopback ? code : nil
    }
```

2. `CLI/MCPService.swift`: give `ResolvedEndpoint` an `isLoopback` property
   and use it in both places.

```swift
    var isLoopback: Bool {
        if case .loopback = self { return true }
        return false
    }
```

   In `run()`, before constructing the proxy:

```swift
                if pairingCode != nil, !plan.isLoopback {
                    await log.warning(
                        "Not sending the pairing code: iMCP was found by Bonjour, not its endpoint file. Approve this client in iMCP instead."
                    )
                }
```

   and pass
   `pairingCode: CLIBootstrap.pairingCodeToSend(pairingCode, resolvedViaLoopback: plan.isLoopback)`.
   In the outer `catch`, replace the six-line `let resolvedWasLoopback` /
   `if case .loopback = resolved` block with
   `let resolvedWasLoopback = resolved?.isLoopback ?? false`.
3. `App/Shared/ListenerEndpointFile.swift`: make the Debug signing exceptions
   apply only to builds that have no team identity. First statement of the
   `#if DEBUG` `acceptsDebugIMCPSigning`:

```swift
            // The exceptions below need no secret to satisfy. They exist for
            // builds with no team identity (CI signs ad hoc); a team-signed
            // build verifies the app against its own team instead.
            guard ownTeamIdentifier == nil else { return false }
```

4. Removed by owner decision 2026-10-12; nothing to do. (Was: user-facing
   copy changes in `ConnectClientWindow.swift` and `README.md`.)

5. Removed by owner decision 2026-10-12; nothing to do. (Was: deleting three
   `--pair` tests in `CLITests/CLIBootstrapTests.swift`. Keep all of them.)

**Verify**:
- `git diff --stat main -- App/Views/ConnectClientWindow.swift README.md` → empty.
- `git grep -c "PairingCodeResolution\|emptyToNil" -- CLI/CLIBootstrap.swift` →
  a count above zero (the `--pair` handling is still there).
- `git grep -n "pairingCodeToSend" -- CLI` → one definition in
  `CLI/CLIBootstrap.swift` and one call in `CLI/MCPService.swift`.
- Build command → exit 0.
- `Scripts/test.sh --cli-only` → all pass.
- `Scripts/test.sh --only iMCPTests/ListenerEndpointFileTests` → all pass,
  including `testAppTestHostIsSignedAsIMCP`. If that one test fails, STOP (see
  STOP conditions); do not weaken it.

Commit: `fix(cli): send the pairing code only over the verified endpoint`

### Step 8: Move the Debug trust store into the Keychain

This step changes where the owner's paired-client list lives. Read it fully
before editing.

1. `App/Controllers/PairedClientStorage.swift`: delete the `#if DEBUG` /
   `#else` backend switch in `production()`, and delete `fileLoad` and
   `fileSave`. Debug and Release now share `keychainLoad` / `keychainSave`.
   Add a one-time adoption of the old file, Debug only:

```swift
    /// Keychain-backed store. Migrates a leftover UserDefaults list once.
    static func production() -> PairedClientStorage {
        let load: () -> KeychainLoadResult = { keychainLoad() }
        let save: (Data) -> Bool = { keychainSave($0) }
        #if DEBUG
            let marker = KeychainItem(service: debugFileAdoptedService)
            adoptDebugFileOnce(
                markerLoad: { marker.load() },
                mark: { marker.save(Data([1])) },
                fileRead: { SecretFileStore.read(secretFileName) },
                fileDelete: { SecretFileStore.delete(secretFileName) },
                keychainSave: save,
                keychainLoad: load
            )
        #endif
        _ = migrateUserDefaultsIfNeeded(
            defaults: .standard,
            keychainLoad: load,
            keychainSave: save
        )
        return PairedClientStorage(keychainLoad: load, keychainSave: save)
    }

    #if DEBUG
        private static let secretFileName = "paired-clients.json"
        private static let debugFileAdoptedService = keychainService + ".debug-file-adopted"

        /// Debug builds before plan 043 kept the paired list in a plain file.
        /// This moves it into the Keychain exactly once. The file wins over
        /// whatever the Keychain holds, because it was the live store. The
        /// marker lives in the Keychain, so a file that appears later is never
        /// read. The file is deleted only after the Keychain reads back the
        /// same bytes. Returns true when a list was adopted.
        @discardableResult
        static func adoptDebugFileOnce(
            markerLoad: () -> KeychainItem.LoadResult,
            mark: () -> Bool,
            fileRead: () -> SecretFileStore.Read,
            fileDelete: () -> Bool,
            keychainSave: (Data) -> Bool,
            keychainLoad: () -> KeychainLoadResult
        ) -> Bool {
            // `.data` means done; `.failed` means the Keychain is unreadable
            // right now, and adopting blind could repeat on every launch.
            guard markerLoad() == .missing else { return false }
            switch fileRead() {
            case .failed:
                return false
            case .missing:
                _ = mark()
                return false
            case .data(let data):
                guard (try? JSONDecoder().decode([PairedClient].self, from: data)) != nil,
                    keychainSave(data), keychainLoad() == .data(data), mark()
                else { return false }
                _ = fileDelete()
                return true
            }
        }
    #endif
```

   Every failure path leaves the file untouched and the marker unset, so the
   next launch retries. Do not add logging of the list's contents.
2. `App/Shared/SecretFileStore.swift`: delete `static func write`. Update the
   type's doc comment to say the store is now read-and-delete only and exists
   to let Debug builds migrate files written by earlier builds.
3. Rollback property to preserve (do not "tidy" it away): if this commit is
   later reverted, the old Debug code finds no file, reads the Keychain item,
   and copies it back to a file. Nothing in this step deletes the Keychain item.

**Verify**:
- `git grep -n "SecretFileStore.write\|fileSave\|fileLoad()" -- App` → no matches.
- `git grep -n "SecretFileStore\." -- App` → only `.read(` and `.delete(` calls.
- Build command → exit 0.
- `Scripts/test.sh --only iMCPTests/PairedClientStoreTests` → all pass.

Commit: `fix: keep the Debug paired-client list in the Keychain, migrating the old file once`

### Step 9: Create the CLI key file owner-only from the first byte

1. `CLI/main.swift`: immediately after the imports, before `var log`, add:

```swift
// This process only ever creates one file, the Debug signing key. Create it,
// and any directory made for it, owner-only from the start rather than
// tightening the mode after the write.
umask(0o077)
```

   If `umask` does not resolve, add `import Darwin` to the imports.
2. `CLI/ClientKeyStore.swift`, `writeSigningKeyFile`: pass
   `attributes: [.posixPermissions: 0o700]` to `createDirectory`. That applies
   only to directories this call creates; an existing directory named by
   `IMCP_KEY_FILE` is left alone. Keep the existing `setAttributes` `0o600`
   line (it is what the unit test can observe).

Do not change where the key is stored, the `IMCP_KEY_FILE` override, or the
Keychain carry-over in `loadSigningKeyFromDebugFile`.

**Verify**: build command → exit 0; `git grep -n "umask" -- CLI` → one match in `CLI/main.swift`.

Commit: `fix(cli): create the signing key file owner-only`

### Step 10: Tests, format, full run

Add the tests listed in "Test plan", then:

**Verify**:
- `swift format -i -r .` then `swift format lint --strict --recursive .` → exit 0.
- `Scripts/test.sh` → all pass.
- `git status --short` → only in-scope files modified.

Commit: `test: cover setup reaping, signature denial, code lockout, name sanitising, and trust-store adoption`

### Step 11 (OPERATOR, after install — not for the executor)

Report these to the operator; do not perform them. After the operator next
runs `Scripts/install-local.sh run` and restarts the app:

- Settings › Clients lists the same clients as before (compare by count and
  truncated fingerprint; do not print file contents).
- `ls ~/Library/Application\ Support/iMCP/paired-clients.json` reports no such file.
- `plug server disable imcp && plug server enable imcp` reconnects without an
  approval prompt.

If the Clients list is empty and the file is still present, the Keychain write
did not round-trip: the file is intact, nothing was lost, and reverting the
step 8 commit restores the previous behaviour.

## Test plan

All in existing files. No new test file, no `project.pbxproj` edit.

`iMCPTests/ServerNetworkManagerAuthTests.swift` (structural pattern: the
existing `testWrongPairingCodeDoesNotAutoPair` in the same file — `makeManager()`,
`testRegisterConnectionForTesting`, `processAuthResponse`):

- `testSetupWithNoAuthResponseIsStalled` — `ServerNetworkManager.isStalledSetup(ConnectionSession())`
  is `true`. This is the regression test for the dead timeout: a freshly
  accepted session with nothing else set must count as stalled.
- `testVerifiedOrWaitingSetupIsNotStalled` — `false` for
  `auth: .verifiedUnpaired`, `auth: .preAuthenticated`, `phase: .awaitingApproval`,
  `phase: .approved`; `true` for `auth: .invalidSignature`.
- `testInvalidSignatureIsDeniedWithoutPrompting` — sign a response for one
  `AuthChallengeFrame(connectionID: id)`, pass it to `processAuthResponse`
  with a **second** `AuthChallengeFrame(connectionID: id)` (fresh nonce, so
  verification fails), then call `decideApproval(for:clientInfo:using:)` with a
  handler that records that it was called and returns `true`. Assert the
  result is `false` and the handler was never called. Build the
  `MCP.Client.Info` the way the file's existing tests or 037's replacement
  test do; if none exists, `MCP.Client.Info(name: "test", version: "1")`.
- `testUnapprovedSessionCap` — register `ServerNetworkManager.maxUnapprovedSessions`
  connections with `testRegisterConnectionForTesting`; assert
  `hasRoomForUnapprovedSession` is `false`; approve one with
  `markConnectionApproved(_:clientName:)`; assert it is `true`.
- Extend `testValidPairingCodeAutoPairsClient`: approve with
  `clientName: "Claude\u{202E}\nCode"` and assert the stored label equals
  `"ClaudeCode"`.

`iMCPTests/PairingCodeIssuerTests.swift` (pattern: `testWrongCodeRejected`):

- `testCodeIsDiscardedAfterThreeWrongGuesses` — three wrong validations, then
  the correct code returns `false`.
- `testCodeSurvivesTwoWrongGuesses` — two wrong validations, then the correct
  code returns `true`.

`iMCPTests/ConnectionApprovalPairingTests.swift` (pattern: `testApproveWithPairCreatesClient`):

- `testSanitizedClientName` — plain name unchanged; newline, tab, NUL,
  U+202E and U+200B removed; a 200-character name truncated to 64; empty and
  whitespace-only become `"Unknown client"`.

`iMCPTests/PairedClientStoreTests.swift` (pattern:
`testMigrateDeletesUserDefaultsOnlyAfterKeychainReadback`, which drives a
static migration with closures over local `var`s), wrapped in `#if DEBUG`:

- `testDebugFileIsAdoptedOnceAndDeletedAfterReadback` — marker missing, file
  holds an encoded `[PairedClient]`, Keychain holds a different older list:
  returns `true`; Keychain now equals the file bytes; marker set; delete called.
- `testDebugFileIsKeptWhenKeychainReadbackDiffers` — `keychainSave` returns
  `true` but `keychainLoad` returns other bytes: returns `false`; delete not
  called; marker not set.
- `testDebugFileIsIgnoredOnceMarked` — marker `.data`: returns `false`; no
  save, no delete, even though a file is present.
- `testMissingDebugFileSetsMarker` — file `.missing`: marker set; no save.
- `testUnreadableOrUndecodableDebugFileIsLeftAlone` — file `.failed`, and file
  `.data(Data("not-json".utf8))`: no save, no delete, marker not set.

`CLITests/CLIBootstrapTests.swift` (pattern: `testDiscoveryReturnsToLoopbackAfterBonjourFailure`):

- `testPairingCodeIsSentOnlyOverLoopback` —
  `pairingCodeToSend("ABCD23", resolvedViaLoopback: true) == "ABCD23"`,
  `... false) == nil`, and `nil` in gives `nil` out.
- `testNewKeyFileAndDirectoryAreOwnerOnly` — set `IMCP_KEY_FILE` (with
  `setenv` / `defer unsetenv`, as `testResolvedPairingCodeFromEnvironment`
  does) to `<temp>/<uuid>/sub/client-key`, call `ClientKeyStore.loadSigningKey()`,
  assert it is non-nil, the file's `.posixPermissions` is `0o600` and the
  `sub` directory's is `0o700`. Remove the temp directory in a `defer`. Assert
  on attributes only; never read the file.

Not unit-tested, verified by grep in the steps: the stale write-back (step 3;
there is no seam to interleave a removal inside the issuer's `await`), the
window re-check (step 6), and the `umask` call (step 9).

Verification: `Scripts/test.sh` → all pass, including the 14 new tests.

## Done criteria

- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `Scripts/test.sh` exits 0; the new tests listed above exist and pass
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `git grep -n "setupTask" -- App iMCPTests` returns no matches
- [ ] `git grep -c "PairingCodeResolution\|emptyToNil" -- CLI/CLIBootstrap.swift` returns a count above zero (`--pair` handling kept)
- [ ] `git grep -c "func testResolvedPairingCode\|func testPairingCodeResolution" -- CLITests/CLIBootstrapTests.swift` returns `4` (no existing pairing-code test deleted)
- [ ] `git diff --stat main -- App/Views/ConnectClientWindow.swift README.md` is empty
- [ ] `git grep -n "pairingCodeToSend" -- CLI/MCPService.swift` returns one match
- [ ] `git grep -n "SecretFileStore.write\|fileSave" -- App` returns no matches
- [ ] `git grep -n '"Paired Client"' -- App` returns no matches
- [ ] `git grep -n "umask" -- CLI` returns exactly one match
- [ ] No files outside the in-scope list are modified (`git status --short`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 037 is not merged, or `PairedClientStorage.production()` is still
  reachable when the app is launched as the XCTest host (step 0). Step 8 would
  then migrate the owner's real trust store from a test run.
- Any "Current state" excerpt does not match the live code, other than the
  differences listed under "Expected drift from plan 037".
- `App/App.Debug.entitlements` no longer contains `keychain-access-groups`.
  Without it Debug falls back to the file keychain, which prompts after every
  rebuild; do not do step 8.
- You cannot make step 8 satisfy all three of: the file wins over an existing
  Keychain item; the file is deleted only after a matching read-back; a failed
  step leaves the file in place. Losing the paired list makes every client,
  including the owner's `plug` client, prompt again.
- `ListenerEndpointFileTests.testAppTestHostIsSignedAsIMCP` fails after step 7.
  That means the local test host has a team identity that the release
  requirement does not accept; revert the `acceptsDebugIMCPSigning` guard,
  keep the rest of step 7, and report it.
- A step would require running `Scripts/install-local.sh`, reading or printing
  the contents of `paired-clients.json`, a client key file, or any Keychain
  item, changing a System Settings privacy grant, or `launchctl bootout` of
  the always-on agent.
- The build rejects the `decideApproval` call site for an isolation reason you
  cannot resolve by keeping the closure body exactly as shown.
- A step's verification fails twice after a reasonable fix attempt, or the fix
  appears to need an out-of-scope file (in particular `CLI/StdioProxy.swift`
  or `App/Shared/AuthPreamble.swift`).
- A step appears to need a change to `--pair` handling, its tests, or its copy
  in `ConnectClientWindow.swift` / `README.md`. Those are out of scope by
  owner decision.

## Maintenance notes

- **Do not install as part of this plan.** `Scripts/install-local.sh run` is
  the operator's call. Step 11 lists what the operator should check afterwards.
- **Delete the adoption block later.** Once the operator confirms
  `paired-clients.json` is gone, `adoptDebugFileOnce`, `secretFileName`,
  `debugFileAdoptedService` and the `#if DEBUG` block in `production()` can be
  deleted, leaving `PairedClientStorage` with no Debug-specific code. When the
  iCloud Debug migration is retired too, `SecretFileStore.swift` can be deleted
  whole.
- **Review the adopted list once.** The file being adopted was writable by any
  process running as the owner. Adoption preserves exactly today's trust, no
  more; the owner should glance at Settings › Clients after the first launch
  and remove anything unrecognised.
- **No notification on code pairing.** A client paired by code is still added
  without a prompt; that is the feature. This plan makes the entry
  identifiable (it now carries the client's name) and narrows when a code is
  accepted (verified endpoint only, three guesses). A system notification was
  considered and left out: the app does not use `UNUserNotificationCenter`
  today, and adding it brings a new permission prompt. If the owner wants one,
  the hook is the `pendingPairCommit` branch of `markConnectionApproved`.
- **`--pair` removal was considered and reversed.** An earlier draft deleted
  the `--pair <code>` flag and took the code from `IMCP_PAIR_CODE` only,
  because process arguments are visible to other local processes. The owner
  reversed this on 2026-10-12: removing the flag is a usability loss for a
  marginal gain. The code is one-time and short-lived, and a same-user process
  that can read argv can already read far more. The argv exposure is accepted.
  Do not re-propose the removal without new evidence.
- **Residual: the app is not authenticated to the CLI.** The endpoint file
  proves which process wrote it, not which process is listening on the port
  (see the doc comment on `ListenerEndpointFile.readValidated`). Closing that
  needs a server-signed frame in the preamble, which is a wire-format change
  with a protocol version bump (`App/Shared/AuthPreamble.swift:164-186` is
  already tight on extension parsing). Deferred.
- **Residual: Debug signing exceptions.** After step 7 they apply only to
  builds with no team identity (CI). The "Plug Local Signing" requirement is
  tied to `Scripts/install-local.sh`'s default identity, which plan 050
  revisits; if 050 removes that default, delete `debugPlugLocalRequirement`
  and its compiled copy as well.
- **Residual: the CLI key stays a file in Debug.** The CLI has no entitlements
  and cannot reach the data-protection keychain. If the CLI ever gets its own
  entitlements, revisit `ClientKeyStore`. Existing key files are not re-checked
  for loose permissions on read; that was left out to avoid locking out the
  `plug` key.
- **Accepted, not changed:** service on/off toggles live in UserDefaults and
  can be flipped by any process running as the owner. That is the accepted
  trust boundary for this app (it is not sandboxed).
- **`KeychainItem.load` adopts a file-keychain item without checking who wrote
  it** (`App/Models/KeychainItem.swift:109-120`). Low risk (writing there
  already needs the login keychain); kept because unentitled builds rely on
  the fallback.
- **Interactions.** Plan 044 adds `CLI/MCPService.swift` to the CLI test
  target; once it has, `ResolvedEndpoint.isLoopback` and the withheld-code
  warning can be tested end to end. Plan 048 rewrites the timer in
  `ConnectClientWindow.swift`; this plan does not touch that file. If a `clientName` ever reaches the UI by a path other than the
  approval handler in `ServerController`, it must go through
  `sanitizedClientName` too.
- **Reviewer focus.** (1) Step 8's ordering: save, read back, mark, then
  delete. (2) Step 1: that nothing else depended on `setupTask` being
  cancelled. (3) Step 7: that the code is withheld on the Bonjour path and that
  `--pair` handling, its tests and its copy are untouched.
