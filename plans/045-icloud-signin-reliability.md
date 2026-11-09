# Plan 045: Make iCloud sign-in tell the truth, keep the password only where it belongs, and never lose a cookie rotation on Quit

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- App/Services/Location/ICloudAuthClient.swift App/Services/Location/ICloudCredentialStorage.swift App/Controllers/ICloudSession.swift App/Views/ICloudSignInWindow.swift App/App.swift iMCPTests/ICloudAuthFlowTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (touches the sign-in state machine; every change is covered by the scripted-transport tests, none can be checked against Apple by an agent)
- **Depends on**: plans/037-isolate-tests-from-real-state.md
- **Category**: bug, security
- **Planned at**: commit `8165d29`, 2026-10-12 (branch `feat/menu-bar-resilience`, PR #61)

## Why this matters

iMCP signs in to iCloud with the user's Apple ID so the Location tools can
read Find My. Several small defects in that path each make the app either lie
to the user or hold a secret longer than it needs to:

- An Apple protocol change, an unexpected status, or an undecodable challenge
  is reported as "Apple rejected that Apple ID and password", which is a
  *permanent* failure that drops the session. The user is told their password
  is wrong when it is not.
- A failed manual sign-in shows "Not signed in" while the previous session and
  its saved password are still in the Keychain, and no screen in that state
  offers Sign Out, so the user cannot remove them.
- The Apple ID password stays in actor memory for the life of the process, and
  a typed-but-unsubmitted password or code stays in a closed window's view
  state for the life of the process.
- Quit from the menu, logout and shutdown skip the cookie flush, so up to
  60 seconds of Apple's cookie rotation is lost and the next launch can start
  from a dead jar.
- The two-factor screen has no way out, Return submits empty fields, restored
  cookies lose their Secure flag, service endpoints are accepted from any
  host, and Sign Out leaves the live cookie jar in memory.

**Owner decision, already made — do not revisit**: the Apple ID password
stays saved in the this-device-only data-protection Keychain, always, with no
opt-in checkbox. It is what lets iMCP sign in again silently. The sign-in
sheet already discloses it (`App/Views/ICloudSignInWindow.swift:119-122`) and
Sign Out deletes it (`ICloudAuthClient.signOut`). **Do NOT add a toggle, a
checkbox, or a "remember password" preference.** This plan only makes the
existing promise true: one durable copy (the Keychain), and Sign Out always
reachable.

The owner's standing preference is improvement by subtraction. Where this plan
can delete a branch, a duplicate, or a dead function instead of adding a
guard, it does.

## Current state

All excerpts are from commit `8165d29`.

### Files and roles

- `App/Services/Location/ICloudAuthClient.swift` (1247 lines) — `actor ICloudAuthClient`: SRP sign-in, 2FA, account login, persistence, cookie restore. Also `ICloudAccount` and `ICloudAuthError`.
- `App/Services/Location/ICloudCredentialStorage.swift` (330 lines) — `ICloudCredentials`, `ICloudStoredCookie`, Keychain persistence with `load()` (blocking) and `load(within:)` (deadline, off the caller).
- `App/Controllers/ICloudSession.swift` (802 lines) — `@MainActor final class ICloudSession`: the UI-facing state machine (`State`: `signedOut`, `working`, `awaitingCode`, `signedIn`, `needsReauthentication`, `credentialsUnreadable`).
- `App/Views/ICloudSignInWindow.swift` (190 lines) — the sign-in window, its controller, and `ICloudSignInPresenter`.
- `App/App.swift` (104 lines) — `App` scene and `AppDelegate`.
- `App/Services/Location/ICloudHTTP.swift` — `ICloudHTTPTransport` protocol (`clearCookies()`, `setCookies`, `allCookies()`). Read-only for this plan.
- `iMCPTests/ICloudAuthFlowTests.swift` (3161 lines) — every test for the above. Fixtures at `:12-284`: `ScriptedTransport` (scripted replies, an in-memory cookie `jar`), `accountLoginBody()`, `challengeBody`, `storageInMemory()`, `countingStorageInMemory()`, `storageThatFailsToLoad()`.

### 1. Wrong "invalid credentials" (`ICloudAuthClient.swift`)

`:611-623` — undecodable values silently become empty/default:

```swift
    private struct SRPChallenge {
        let salt: String
        let b: String
        let c: String
        let iteration: Int
        let `protocol`: String

        var saltData: Data { Data(base64Encoded: salt) ?? Data() }
        var serverPublicKeyData: Data { Data(base64Encoded: b) ?? Data() }
        var passwordProtocol: SRPPasswordProtocol {
            SRPPasswordProtocol(rawValue: `protocol`) ?? .s2k
        }
    }
```

`:643-650` (`beginSRP`) — any non-2xx that is not 429/5xx is a wrong password:

```swift
        guard response.isSuccess else {
            // Apple being down or throttling is not a wrong password. Saying
            // so would end a session the stored password could still renew.
            if Self.isTransientStatus(response.statusCode) {
                throw ICloudAuthError.appleRejectedRequest(status: response.statusCode)
            }
            throw ICloudAuthError.invalidCredentials
        }
```

`:696-711` (`completeSRP`) — same:

```swift
        if response.isSuccess { return .signedIn }

        // 409 with `authType: hsa2` is Apple's "now do the second factor". Any
        // other failure at this point means the password was wrong, unless
        // Apple could not answer at all.
        if Self.isTransientStatus(response.statusCode) {
            throw ICloudAuthError.appleRejectedRequest(status: response.statusCode)
        }
        guard
            response.statusCode == 409,
            let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            (body["authType"] as? String) == "hsa2"
        else {
            throw ICloudAuthError.invalidCredentials
        }
        return .needsTwoFactorCode
```

`:1173-1175` — `isTransientStatus` has exactly those two callers.

`.invalidCredentials` is in `isPermanentReauthFailure` (`:131-138`), so
`ICloudSession.reauthenticateSilently` (`ICloudSession.swift:502-513`) drops
the session and asks for a sign-in. `SRPPasswordProtocol` lives in
`Packages/SRP/Sources/SRP/SRPClient.swift:7` (`case s2k`, `case s2kFO = "s2k_fo"`).

The repo's own tests encode "401 on `signin/complete` is the wrong password"
(`ICloudAuthFlowTests.swift:412-426`, `:943-955`). No test expects
`.invalidCredentials` for any other status.

### 2. Password kept in actor memory (`ICloudAuthClient.swift`)

- `:246` `private var pendingPassword: String?`
- `:407` `pendingPassword = password` (private `signIn`)
- `:591` `pendingPassword = nil` (`signOut` — the only place it is cleared)
- `:1076` `pendingPassword = credentials.password` (`hydrate`, run on every `restore`, `refreshAccount`, `validateCurrentSession`)
- `:988` `password: pendingPassword,` (`persist`)
- `:1050` `updated.password = pendingPassword ?? updated.password` (`persistRepairPending`)

`persist` (`:968-971`) and `persistRepairPending` (`:1021-1024`) each contain
this identical block:

```swift
        let previous: ICloudCredentials? = {
            guard case .credentials(let existing) = storage.load() else { return nil }
            return existing
        }()
```

`reauthenticate()` (`:338-378`) reads the password from the Keychain itself
(`:347`) and passes it to `signIn`; it does not depend on `hydrate`. Its
catch-all (`:369-376`):

```swift
            } catch {
                // Preserve the last stored session after a failed unattended
                // replacement. Direct Find My probes can still recover it.
                try requireCurrent(generation)
                transport.clearCookies()
                hydrate(from: credentials)
                throw error
            }
```

### 3. Sign Out leaves the cookie jar; restored cookies lose Secure; endpoints unchecked (`ICloudAuthClient.swift`)

`:584-595`:

```swift
    func signOut() throws {
        authenticationGeneration &+= 1
        guard storage.clear() else {
            throw ICloudAuthError.couldNotClearSession
        }
        state = ICloudAuthState()
        pendingAccountName = nil
        pendingPassword = nil
        pendingDelivery = nil
        pendingAuthenticationGeneration = nil
        pendingAutomaticReauthenticationAt = nil
    }
```

`restoreCookies` (`:1080-1123`) builds cookies from two property dictionaries,
neither with `.secure` (`:1087-1092` and `:1107-1112`). `ICloudStoredCookie`
(`ICloudCredentialStorage.swift:16-22`) has no `isSecure` field. Do not add
one: every cookie Apple sets here is Secure, so restore sets the flag
unconditionally and the stored format does not change.

`ICloudAccount.init(accountLoginBody:)` (`:67-75`):

```swift
        var services: [String: URL] = [:]
        for (key, value) in root["webservices"] as? [String: Any] ?? [:] {
            guard
                let entry = value as? [String: Any],
                let text = entry["url"] as? String,
                let url = URL(string: text)
            else { continue }
            services[key] = url
        }
```

Service calls to these URLs carry the session's cookies. Only
`webservices["findme"]` is ever used (`:49`, `:89`). Test fixtures use
`https://p42-fmipweb.icloud.com:443` and `https://p42-remindersws.icloud.com:443`.

### 4. Session state (`ICloudSession.swift`)

`:275-282` (`signIn`):

```swift
        } catch ICloudAuthError.accountRepairRequired {
            guard generation == operationGeneration else { return }
            requireAccountRepair(keepExistingSession: false)
        } catch {
            guard generation == operationGeneration else { return }
            state = .signedOut
            failure = message(for: error)
        }
```

`:297-303` (`submitTwoFactorCode`):

```swift
        } catch ICloudAuthError.sessionExpired {
            guard generation == operationGeneration else { return }
            // Apple has thrown the session away, so no further code can be
            // submitted against it. Leaving the code field up would only
            // collect another rejection.
            state = .signedOut
            failure = ICloudAuthError.sessionExpired.errorDescription
```

A manual `signIn` writes nothing until it succeeds, so after either failure
the previous `ICloudCredentials` (password included) are still in the
Keychain. `App/Views/SettingsView.swift:174-186` shows Sign Out only when
`session.isSignedIn`, and the sign-in window shows it only in `.signedIn`
(`ICloudSignInWindow.swift:73-74`), so in `.signedOut` and
`.needsReauthentication` nothing can delete them.

`:774-777` — a blocking Keychain read on the main actor:

```swift
    private func storedAccountName() -> String? {
        guard case .credentials(let credentials) = storage.load() else { return nil }
        return credentials.accountName
    }
```

Callers: `:570` (`keepSessionAfterTransientFailure`) and `:771` (`adopt`).
`ICloudCredentialStorage.swift:251-252` documents `load()` as "Call this only
from a context that can afford to block". The auth client already holds the
name: `pendingAccountName` is set by `hydrate` (`ICloudAuthClient.swift:1075`)
and by `signIn` (`:406`), which is every path that ends in `adopt`.
`ICloudAuthClient.currentClientID()` (`:270`) is the existing accessor to copy.

`:655-665` — `func invalidate(reason: InvalidationReason)` has no callers
anywhere (`git grep -n "invalidate(reason" -- '*.swift'` returns only its
definition). `InvalidationReason` itself is used throughout and stays.

`:247-257` — `beginManualSignIn()` already exists and sets
`.needsReauthentication`; it is called from `SettingsView.swift:167`.

### 5. Sign-in window (`ICloudSignInWindow.swift`)

`:20-47` — the presenter keeps the controller forever, so the hosting view and
its `@State` (`:55-57`: `accountName`, `password`, `code`) outlive a closed
window:

```swift
    static func showReplacing(
        _ existing: ICloudSignInWindowController?,
        session: ICloudSession
    ) -> ICloudSignInWindowController {
        existing?.close()
        let next = ICloudSignInWindowController(session: session)
        next.showWindow(nil)
        next.window?.makeKeyAndOrderFront(nil)
        return next
    }
}
...
@MainActor
enum ICloudSignInPresenter {
    private static var controller: ICloudSignInWindowController?

    static func show() {
        controller = ICloudSignInWindowController.showReplacing(
            controller,
            session: .shared
        )
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

`showReplacing` has one caller (`ICloudSignInPresenter.show`).
`ICloudSignInPresenter.show()` is called from `ServerController.swift:97`,
`ServiceRegistry.swift:63`, `SettingsView.swift:168,182`. Keep its signature.

`:126-156` — `.onSubmit(submitCredentials)` and `.onSubmit(submitCode)` fire
on Return regardless of the buttons' `.disabled` guards, and the 2FA screen
has only the field and Verify:

```swift
    private var codeFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Verification Code", text: $code)
                .textContentType(.oneTimeCode)
                .onSubmit(submitCode)

            HStack {
                Spacer()
                Button("Verify", action: submitCode)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.count < 6)
            }
        }
    }
```

`:179-189`:

```swift
    private func submitCredentials() {
        let submitted = password
        password = ""
        Task { await session.signIn(accountName: accountName, password: submitted) }
    }

    private func submitCode() {
        let submitted = code
        code = ""
        Task { await session.submitTwoFactorCode(submitted) }
    }
```

`.awaitingCode` is also entered without the user asking, by silent re-auth
(`ICloudSession.swift:548-558`).

### 6. Quit (`App/App.swift`, `App/Views/ContentView.swift`)

`App.swift:59-69` — only Cmd-Q flushes:

```swift
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit") {
                    Task {
                        await ICloudSession.shared.flushCookies()
                        NSApplication.shared.terminate(nil)
                    }
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
```

`ContentView.swift:154-156` — the menu's Quit calls
`NSApplication.shared.terminate(nil)` directly. `AppDelegate`
(`App.swift:75-104`, `@Observable final class AppDelegate: NSObject, NSApplicationDelegate`)
has no `applicationShouldTerminate`. `ICloudSession.flushCookies()`
(`ICloudSession.swift:711-714`) returns immediately when not signed in.
The rotated jar is otherwise written at most every 60 s
(`cookieWriteInterval`, `ICloudSession.swift:144`).

### 7. Stale comment (`ICloudCredentialStorage.swift:5-15`)

The doc comment for `ICloudCredentials` is stranded on top of
`ICloudStoredCookie` and is false:

```swift
/// What iMCP keeps after an iCloud sign-in.
///
/// The password is not here and is never written anywhere. These are the
/// tokens Apple hands back, which is what a later launch replays to get a
/// session without asking the user again.
/// One session cookie, flattened so it survives in JSON.
///
```

`:48-54` of the same file declares `var password: String?` with an accurate
comment.

### Conventions that apply

- Swift 6 strict concurrency, warnings are errors. Local Xcode is 27 beta, CI is Xcode 26.0. Xcode 27 adds two diagnostics that fail the build: `ImplicitStrongCapture` (write `Task { [self] in` when a `Task` closure uses `self`) and `NoUseUnstructuredThrowingTask` (do not leave an unused *throwing* `Task`; use `try?` inside).
- All members of a SwiftUI `View` are `@MainActor`-isolated. `NSApplicationDelegate` and `NSWindowDelegate` are `@MainActor` protocols.
- Comments in this code explain *why* in full sentences. Match that voice; do not write comments that restate the code.
- Never log, print, or put into an error message a password, code, token, or cookie value.
- Tests use the scripted transport, never the network. **No agent may ever type an Apple ID password or 2FA code into the running app.** All verification in this plan is by unit test and build.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| One test class | `Scripts/test.sh --only iMCPTests/ICloudAuthFlowTests` (`--only` is repeatable and implies `--app-only`) | all pass |
| iCloud test classes | `Scripts/test.sh --only iMCPTests/ICloudAuthFlowTests --only iMCPTests/ICloudSessionTests --only iMCPTests/ICloudCookiePersistenceTests --only iMCPTests/ICloudSilentReauthenticationTests` | all pass |
| All tests | `Scripts/test.sh` | all pass |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

Never run `xcodebuild test -scheme iMCP` directly: the always-on watchdog
relaunches the installed app and breaks the test host. Never
`launchctl bootout` the always-on agent. If `xcodebuild` reports "failed with
exit code 0 but produced no further output", rerun it once.

## Scope

**In scope** (the only files you should modify):

- `App/Services/Location/ICloudAuthClient.swift`
- `App/Services/Location/ICloudCredentialStorage.swift` (comment only, Step 7)
- `App/Controllers/ICloudSession.swift`
- `App/Views/ICloudSignInWindow.swift`
- `App/App.swift`
- `iMCPTests/ICloudAuthFlowTests.swift` (add tests to existing classes; no new test file, so no `project.pbxproj` edit)

**Out of scope** (do NOT touch, even though they look related):

- Any toggle, checkbox, or preference for saving the password — owner decision above.
- `ICloudStoredCookie` / `ICloudCredentials` stored fields — no schema change.
- `App/Views/SettingsView.swift`, `App/Views/ContentView.swift` — plan 048 owns them (including a confirmation on Sign Out). The menu's Quit needs no edit: it already calls `terminate`, which Step 6 intercepts.
- `App/Services/Location/LocationSampler.swift` and sampling behaviour — plan 047.
- Find My People — plan 046.
- A shared error-text helper for views — plan 042.
- Old plan documents that describe the password as "never stored" — plan 053.
- `Scripts/` — plan 050. A SIGTERM handler (the install script stops the app with `pkill`) is deliberately not added here; see Maintenance notes.
- `App/Services/Location/ICloudHTTP.swift`, `Packages/SRP/`.

## Git workflow

- Start from an up-to-date `main` that already contains PR #61 (`feat/menu-bar-resilience`) and plan 037. Check: `grep -c "final class AppDelegate" App/App.swift` → `1`. If `0`, STOP.
- Branch: `advisor/045-icloud-signin-reliability`.
- One commit per step. Conventional commits, matching the log, e.g. `fix: bring Settings forward from the menu; stay quiet on relaunch`. Suggested messages are given per step.
- Do NOT push or open a PR unless the operator says so. `origin` (`cyberpapiii/iMCP`) is the only writable remote; `upstream` (`mattt/iMCP`) must never receive pushes or PRs.

## Steps

### Step 1: Decode the SRP challenge strictly; call only 401 a wrong password

File: `App/Services/Location/ICloudAuthClient.swift`.

1. Replace `SRPChallenge` (`:611-623`) with decoded fields and no accessors:

   ```swift
       private struct SRPChallenge {
           let salt: Data
           let serverPublicKey: Data
           let c: String
           let iteration: Int
           let passwordProtocol: SRPPasswordProtocol
       }
   ```

2. In `beginSRP`, replace the whole `guard response.isSuccess else { ... }`
   block with one line, and decode inside the existing body guard so anything
   undecodable is `.unreadableResponse`:

   ```swift
           guard response.isSuccess else { throw Self.rejection(status: response.statusCode) }
           guard
               let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
               let salt = (body["salt"] as? String).flatMap({ Data(base64Encoded: $0) }), !salt.isEmpty,
               let serverPublicKey = (body["b"] as? String).flatMap({ Data(base64Encoded: $0) }),
               !serverPublicKey.isEmpty,
               let c = body["c"] as? String,
               let iteration = body["iteration"] as? Int,
               let passwordProtocol = (body["protocol"] as? String).flatMap(SRPPasswordProtocol.init(rawValue:))
           else {
               throw ICloudAuthError.unreadableResponse
           }
           return SRPChallenge(
               salt: salt,
               serverPublicKey: serverPublicKey,
               c: c,
               iteration: iteration,
               passwordProtocol: passwordProtocol
           )
   ```

3. In private `signIn` (`:424-434`) rename the uses: `challenge.saltData` →
   `challenge.salt` (two places), `challenge.serverPublicKeyData` →
   `challenge.serverPublicKey`. `challenge.iteration`,
   `challenge.passwordProtocol` and `challenge.c` keep their names.

4. In `completeSRP`, delete the `isTransientStatus` branch and its comment;
   the result is:

   ```swift
           if response.isSuccess { return .signedIn }

           // 409 with `authType: hsa2` is Apple's "now do the second factor".
           guard
               response.statusCode == 409,
               let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
               (body["authType"] as? String) == "hsa2"
           else {
               throw Self.rejection(status: response.statusCode)
           }
           return .needsTwoFactorCode
   ```

5. Replace `isTransientStatus` (`:1171-1175`, doc comment included) with:

   ```swift
       /// 401 is how Apple answers a wrong Apple ID or password. Every other
       /// status (throttling, an outage, a changed protocol) says nothing
       /// about the credentials, and calling it a wrong password would end a
       /// session the stored password could still renew.
       private static func rejection(status: Int) -> ICloudAuthError {
           status == 401 ? .invalidCredentials : .appleRejectedRequest(status: status)
       }
   ```

**Verify**:
- `grep -n "isTransientStatus\|?? Data()\|?? .s2k\|saltData\|serverPublicKeyData" App/Services/Location/ICloudAuthClient.swift` → no output.
- Build command → exit 0.

Commit: `fix(icloud): report only a 401 as a wrong password; reject an undecodable challenge`

### Step 2: Keep the password in actor memory only until the session is saved

File: `App/Services/Location/ICloudAuthClient.swift`.

1. Add a doc comment to the property at `:246`:

   ```swift
       /// Held from `signIn` until the session is saved, then dropped. The
       /// Keychain copy is the one that lasts; `reauthenticate()` reads it
       /// from there.
       private var pendingPassword: String?
   ```

2. Add one helper in the `// MARK: - Persistence` section and use it in both
   `persist` and `persistRepairPending` in place of the two identical
   `let previous: ICloudCredentials? = { ... }()` closures:

   ```swift
       /// The snapshot a write is about to replace. With a password in hand
       /// the write is complete without it. Without one, the stored copy is
       /// the only copy, and writing blind would erase it.
       private func snapshotToReplace() throws -> ICloudCredentials? {
           switch storage.load() {
           case .credentials(let existing): return existing
           case .missing: return nil
           case .unavailable:
               if pendingPassword == nil { throw ICloudAuthError.credentialsUnreadable }
               return nil
           }
       }
   ```

   Call site in both functions: `let previous = try snapshotToReplace()`.

3. In `persist`: change `password: pendingPassword,` to
   `password: pendingPassword ?? previous?.password,` and add
   `pendingPassword = nil` as the last statement, after the
   `guard didPersist else { throw ... }`.

4. In `persistRepairPending` (the branch that does not call `persist`): leave
   `updated.password = pendingPassword ?? updated.password` as is and add
   `pendingPassword = nil` as the last statement, after the
   `guard storage.save(updated) else { throw ... }`.

5. In `hydrate` delete the line `pendingPassword = credentials.password`.

6. In `reauthenticate()`'s final `catch` add `pendingPassword = nil` directly
   after `hydrate(from: credentials)`.

Do not change `signOut` (already clears it) or `signIn` (`:407` must keep
setting it: a 2FA sign-in needs it minutes later in `submitTwoFactorCode`).

**Verify**:
- `grep -n "pendingPassword" App/Services/Location/ICloudAuthClient.swift` → exactly these kinds of lines and no others: the declaration; `pendingPassword = password` (signIn); `pendingPassword = nil` four times (reauthenticate catch, signOut, persist, persistRepairPending); the `if pendingPassword == nil` in `snapshotToReplace`; the two `pendingPassword ??` reads. No `pendingPassword = credentials.password`.
- `grep -c "guard case .credentials(let existing) = storage.load()" App/Services/Location/ICloudAuthClient.swift` → `0`.
- Build → exit 0.
- `Scripts/test.sh --only iMCPTests/ICloudSilentReauthenticationTests` → all pass (in particular `testRestoreThenValidationKeepsThePassword` and `testAutomaticGuardSurvivesAKeychainReadFailureDuringSessionPersist`).

Commit: `fix(icloud): drop the in-memory password once the session is saved`

### Step 3: Sign Out empties the jar; restored cookies are Secure; endpoints must be Apple HTTPS

File: `App/Services/Location/ICloudAuthClient.swift`.

1. `signOut()`: add `transport.clearCookies()` on the line after the
   `guard storage.clear() else { ... }` block (after, so a failed clear still
   leaves the session usable, which `testSignOutReportsAFailedClearAndKeepsTheTokens` relies on).

2. `restoreCookies`: add `.secure: "TRUE",` to **both** property dictionaries
   (the per-stored-cookie one and the `X-APPLE-WEBAUTH-*` fallback one). Put
   this comment above the first:

   ```swift
               // Every cookie Apple sets here is Secure, and the stored form
               // does not record the flag. Without it a restored cookie
               // could be sent over plain HTTP.
   ```

3. `ICloudAccount`: add a static check and use it in the `guard` of
   `init(accountLoginBody:)`:

   ```swift
       /// Service calls carry the session's cookies, so an endpoint is only
       /// taken when it is HTTPS on Apple's iCloud domain.
       static func isAppleServiceURL(_ url: URL) -> Bool {
           guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
           return host.hasSuffix(".icloud.com") || host.hasSuffix(".icloud.com.cn")
       }
   ```

   ```swift
               guard
                   let entry = value as? [String: Any],
                   let text = entry["url"] as? String,
                   let url = URL(string: text),
                   Self.isAppleServiceURL(url)
               else { continue }
   ```

   A dropped `findme` entry surfaces through the existing
   `guard account.findMy != nil else { throw .webAccessDisabled }`; add no new
   error.

**Verify**:
- `grep -c '.secure: "TRUE"' App/Services/Location/ICloudAuthClient.swift` → `2`.
- `grep -n "transport.clearCookies()" App/Services/Location/ICloudAuthClient.swift` → three lines (reauthenticate catch, private signIn, signOut).
- Build → exit 0.
- `Scripts/test.sh --only iMCPTests/ICloudCookiePersistenceTests --only iMCPTests/ICloudAuthFlowTests` → all pass.

Commit: `fix(icloud): clear cookies on sign-out, restore them Secure, accept only Apple HTTPS endpoints`

### Step 4: Session state — truthful after a failed sign-in, no Keychain read on the main actor, delete dead code

Files: `App/Services/Location/ICloudAuthClient.swift`, `App/Controllers/ICloudSession.swift`.

1. `ICloudAuthClient`: next to `currentClientID()` add

   ```swift
       /// The account the loaded or just-signed-in session belongs to.
       func currentAccountName() -> String? { pendingAccountName }
   ```

2. `ICloudSession`: add a stored property beside `clientID`:

   ```swift
       /// The signed-in account's name, as the auth client reported it at the
       /// last `adopt`. Kept so a state change never needs the Keychain.
       private var accountName = "iCloud"
   ```

3. `adopt(_:)`: directly after `clientID = await client.currentClientID()` add
   `accountName = await client.currentAccountName() ?? "iCloud"`, and change
   the last line to `self.state = .signedIn(accountName: accountName)`. Keep
   both awaits at the top, before any other mutation, as the first one is now.

4. `keepSessionAfterTransientFailure()`: change the last line to
   `state = .signedIn(accountName: accountName)`.

5. Delete `storedAccountName()` (`:774-777`).

6. Delete `invalidate(reason:)` and its doc comment (`:655-665`). Keep
   `InvalidationReason`.

7. Add this helper (place it after `signOut()`):

   ```swift
       /// Where a sign-in that did not finish leaves the UI. A manual attempt
       /// replaces nothing until it succeeds, so an earlier session and its
       /// saved password can still be on disk; calling that signed out would
       /// hide them behind a state that offers no Sign Out.
       private func stateWithoutSession() async -> State {
           if case .missing = await storage.load(within: ICloudCredentialStorage.readDeadline) {
               return .signedOut
           }
           return .needsReauthentication
       }
   ```

8. `signIn`'s final `catch`:

   ```swift
           } catch {
               let fallback = await stateWithoutSession()
               guard generation == operationGeneration else { return }
               state = fallback
               failure = message(for: error)
           }
   ```

   The `await` must come **before** the generation guard, so a sign-out or a
   newer sign-in that lands during the read still wins.

9. `submitTwoFactorCode`'s `catch ICloudAuthError.sessionExpired`: same shape —
   `let fallback = await stateWithoutSession()`, then the generation guard,
   then `state = fallback` (keep the existing comment and the `failure =`
   line).

**Verify**:
- `grep -n "storedAccountName\|func invalidate(reason" App/Controllers/ICloudSession.swift` → no output.
- `grep -n "storage.load()" App/Controllers/ICloudSession.swift` → no output (only `storage.load(within:` remains).
- Build → exit 0.
- `Scripts/test.sh --only iMCPTests/ICloudSessionTests --only iMCPTests/ICloudSilentReauthenticationTests` → all pass. `testWrongPasswordReturnsToSignedOutWithAReason` and `testExpiredSessionSendsTheUserBackToTheStart` must still pass **unchanged** (their storage is empty, so the fallback is `.signedOut`).

Commit: `fix(icloud): keep a failed sign-in honest about the stored session; delete dead invalidate(reason:)`

### Step 5: Sign-in window — release on close, a way out of 2FA, Sign Out when a session is stored, no empty submits

File: `App/Views/ICloudSignInWindow.swift`.

1. Controller: conform to `NSWindowDelegate`, set the delegate in the
   convenience init, delete `showReplacing`, and report the close:

   ```swift
   @MainActor
   final class ICloudSignInWindowController: NSWindowController, NSWindowDelegate {
       convenience init(session: ICloudSession) {
           // ... window construction unchanged ...
           self.init(window: window)
           window.delegate = self
       }

       func windowWillClose(_ notification: Notification) {
           // Dropped on the next turn, not inside the window's own close.
           Task { [self] in ICloudSignInPresenter.didClose(self) }
       }
   }
   ```

2. Presenter (replace the body of the enum; fix its doc comment, which says
   "keeping the one controller alive"):

   ```swift
   /// Shows the sign-in window from anywhere, and lets go of it when it
   /// closes: the view holds whatever was typed, and a closed window must
   /// not keep a password or a code alive.
   @MainActor
   enum ICloudSignInPresenter {
       private static var controller: ICloudSignInWindowController?

       static func show() {
           controller?.close()
           let next = ICloudSignInWindowController(session: .shared)
           controller = next
           next.showWindow(nil)
           next.window?.makeKeyAndOrderFront(nil)
           NSApp.activate(ignoringOtherApps: true)
       }

       static func didClose(_ closed: ICloudSignInWindowController) {
           if controller === closed { controller = nil }
       }
   }
   ```

   The identity check matters: `show()` closes the old controller and installs
   the new one before the old one's deferred `didClose` runs.

3. `credentialFields` button row — Sign Out when a stored session exists:

   ```swift
               HStack {
                   if session.state == .needsReauthentication {
                       Button("Sign Out") {
                           Task { await session.signOut() }
                       }
                   }
                   Spacer()
                   Button("Sign In", action: submitCredentials)
                       .keyboardShortcut(.defaultAction)
                       .disabled(accountName.isEmpty || password.isEmpty)
               }
   ```

4. `codeFields` — Start Over, and one definition of "a complete code":

   ```swift
       /// A pasted code arrives as "123 456" or "123-456". Apple wants the
       /// six digits.
       private var codeDigits: String { code.filter { ("0" ... "9").contains($0) } }
   ```

   ```swift
               HStack {
                   Button("Start Over") {
                       code = ""
                       session.beginManualSignIn()
                   }
                   Spacer()
                   Button("Verify", action: submitCode)
                       .keyboardShortcut(.defaultAction)
                       .disabled(codeDigits.count != 6)
               }
   ```

5. Submit guards (Return bypasses the buttons' `.disabled`):

   ```swift
       private func submitCredentials() {
           guard !accountName.isEmpty, !password.isEmpty else { return }
           let submitted = password
           password = ""
           Task { await session.signIn(accountName: accountName, password: submitted) }
       }

       private func submitCode() {
           let submitted = codeDigits
           guard submitted.count == 6 else { return }
           code = ""
           Task { await session.submitTwoFactorCode(submitted) }
       }
   ```

6. Update the view's doc comment (`:49-51`) to end: "...is cleared the moment
   the attempt is handed off, and the view itself goes when the window
   closes."

Do not touch `window.isReleasedWhenClosed = false` (`:16`).

**Verify**:
- `grep -n "showReplacing" -r App/` → no output.
- `grep -n "windowWillClose\|Start Over\|codeDigits.count" App/Views/ICloudSignInWindow.swift` → at least one line each.
- Build → exit 0.

Commit: `fix(icloud): release the sign-in window on close; add Start Over and Sign Out; ignore empty submits`

### Step 6: Flush cookies on every orderly quit; delete the custom Quit command

File: `App/App.swift`.

1. Add to `AppDelegate`:

   ```swift
       func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
           // Apple rotates the session cookies on every Find My call and the
           // write is debounced by up to a minute. Quitting without it can
           // leave the next launch replaying a dead jar. Whichever of these
           // finishes first ends the app; the reply does not return.
           Task {
               await ICloudSession.shared.flushCookies()
               sender.reply(toApplicationShouldTerminate: true)
           }
           Task {
               try? await Task.sleep(for: .seconds(2))
               sender.reply(toApplicationShouldTerminate: true)
           }
           return .terminateLater
       }
   ```

   Do not add a stored property to `AppDelegate` (it is `@Observable`).

2. Delete the whole `.commands { CommandGroup(replacing: .appTermination) { ... } }`
   modifier (`:59-69`). The system's default Quit item calls `terminate`,
   which now reaches the delegate, as does the menu's Quit in
   `ContentView.swift:154-156` (do not edit that file), logout and shutdown.

**Verify**:
- `grep -c "CommandGroup" App/App.swift` → `0`.
- `grep -rn "flushCookies()" App/ --include=*.swift` → exactly two lines: the definition in `App/Controllers/ICloudSession.swift` and the call in `App/App.swift` inside `applicationShouldTerminate`. (In zsh quote the glob: `--include='*.swift'`.)
- Build → exit 0.

Commit: `fix: flush the iCloud cookie jar on every quit, not only Cmd-Q`

### Step 7: Correct the stranded comment

File: `App/Services/Location/ICloudCredentialStorage.swift`.

Delete lines `:5-9` (the five lines from `/// What iMCP keeps after an iCloud sign-in.`
through `/// session without asking the user again.`) so `ICloudStoredCookie`'s
own comment starts at `/// One session cookie, flattened so it survives in JSON.`
Then put this directly above `struct ICloudCredentials`:

```swift
/// What iMCP keeps after an iCloud sign-in: the tokens Apple hands back, which
/// a later launch replays to get a session without asking the user again, and
/// the Apple ID password (see `password`), which lets the app sign in again by
/// itself when Apple rejects those tokens.
```

**Verify**: `grep -n "never written anywhere" App/Services/Location/ICloudCredentialStorage.swift` → no output. Build → exit 0.

Commit: `docs(icloud): say where the password is kept`

### Step 8: Tests, format, full run

Add the tests in "Test plan", then:

**Verify**:
- `swift format -i -r .` then `swift format lint --strict --recursive .` → exit 0.
- `Scripts/test.sh` → all pass.
- `git status --short` → only the six in-scope files (plus `plans/README.md`).

Commit: `test(icloud): cover sign-in error mapping, password lifetime, cookie and endpoint checks`

## Test plan

All in `iMCPTests/ICloudAuthFlowTests.swift`, added to existing classes. Copy
the `@MainActor` / `async throws` attributes from the neighbouring test in the
same class. Keep fixtures small (Xcode 26 type-check timeouts on large
literals): reuse `challengeBody`, `accountLoginBody()`, `storageInMemory()`.

**`ICloudAuthFlowTests`** — model on `testWrongPasswordIsNotMistakenForATwoFactorPrompt` (`:412`):

1. `testAnUnexpectedStatusIsNotCalledAWrongPassword` — `signin/complete` status 403 → thrown error equals `.appleRejectedRequest(status: 403)`. Second client: `signin/init` status 400 → `.appleRejectedRequest(status: 400)`.
2. `testAnUndecodableChallengeIsUnreadableNotAWrongPassword` — `signin/init` returns `challengeBody` with `"salt"` replaced by `"not base64!"` → `.unreadableResponse`; a second client with `"protocol": "s3k"` → `.unreadableResponse`. In both, `transport.requests(matching: "signin/complete").isEmpty`.
3. `testSignOutEmptiesTheCookieJar` — model on `testSignOutClearsTheStoredSession` (`:752`): sign in, `transport.setCookies([...], for: ICloudEndpoint.home)` with one cookie, `try await client.signOut()`, assert `transport.allCookies().isEmpty`.
4. `testAccountLoginKeepsOnlyAppleHTTPSEndpoints` — call `ICloudAccount(accountLoginBody:)` on JSON data with `dsInfo.dsid` and four `webservices`: `https://p42-fmipweb.icloud.com:443` (kept), `https://p42-fmipweb.icloud.com.cn:443` (kept), `http://p42-fmipweb.icloud.com` (dropped), `https://evilicloud.com` (dropped). Assert the resulting `webservices.keys`.

**`ICloudCookiePersistenceTests`** — model on `testFindMyHostCookiesSurvivePersistenceAndRestore` (`:2232`), using `ScriptedTransport`:

5. `testRestoredCookiesAreSecure` — save `storedCredentials(cookies: [storedWebAuthCookie("v")])`, `_ = try await client.restore()` (cached endpoints, no network), assert `!transport.allCookies().isEmpty` and `transport.allCookies().allSatisfy(\.isSecure)`. Second case: `storedCredentials(cookies: [])` plus `transport.stub("validate", json: accountLoginBody())` exercises the `X-APPLE-WEBAUTH-*` fallback; same assertion.

**`ICloudSilentReauthenticationTests`** — use its `stubSignIn` and `stored(password:)` helpers:

6. `testValidationWritesTheStoredPasswordNotOneLeftInMemory` — sign in with `"pw"`; decode the saved credentials, set `password = "changed-on-disk"`, `storage.save` it; `transport.stub("validate", json: accountLoginBody())`; `_ = try await client.validateCurrentSession()`; assert the saved password is `"changed-on-disk"`. (Fails before Step 2, when the in-memory `"pw"` is written back.)
7. `testAnUnreadableKeychainDuringValidationDoesNotEraseThePassword` — copy the counting `Box` storage from `testAutomaticGuardSurvivesAKeychainReadFailureDuringSessionPersist` (`:2693`, second load fails); seed `stored(password: "pw")` with `webservices = nil`; stub `validate`; `client.restore()` must throw `.credentialsUnreadable`; the box's data still decodes with `password == "pw"`.

**`ICloudSessionTests`** — model on `testWrongPasswordReturnsToSignedOutWithAReason` (`:943`):

8. `testAFailedSignInOverAStoredSessionAsksToSignInAgain` — `storage.save(...)` a minimal `ICloudCredentials` first (as in `testStoredSessionSignsInAtLaunchWithoutAPrompt`, `:841`), do **not** restore, stub `signin/complete` status 401, `await session.signIn(...)`; assert `session.state == .needsReauthentication` and the failure is `ICloudAuthError.invalidCredentials.errorDescription`. Then `await session.signOut()`; assert `session.state == .signedOut` and `stored()` is nil.
9. `testAnExpiredCodeOverAStoredSessionAsksToSignInAgain` — copy `testExpiredSessionSendsTheUserBackToTheStart` (`:924`) with a stored session saved first; assert `.needsReauthentication`.

No test is written for the window controller or `applicationShouldTerminate`:
both need a live `NSApp` (replying to terminate would end the test host).
Their checks are the greps and the build in Steps 5 and 6.

Verification: `Scripts/test.sh` → all pass, including 9 new tests.

## Done criteria

ALL must hold:

- [ ] Build command exits 0.
- [ ] `swift format lint --strict --recursive .` exits 0.
- [ ] `Scripts/test.sh` exits 0; the 9 tests named above exist and pass.
- [ ] `grep -rn "isTransientStatus\|storedAccountName\|showReplacing\|func invalidate(reason\|CommandGroup\|never written anywhere" App/` returns no matches.
- [ ] `grep -c "pendingPassword = credentials.password" App/Services/Location/ICloudAuthClient.swift` → `0`.
- [ ] `grep -c "applicationShouldTerminate" App/App.swift` → at least `1`.
- [ ] No toggle or preference for saving the password was added: `git diff main -- App/ | grep -ci "AppStorage\|Toggle("` → `0`.
- [ ] No files outside the in-scope list are modified (`git status --short`).
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- `App/App.swift` has no `AppDelegate` class (PR #61 is not merged into your base).
- Any "Current state" excerpt does not match the live code.
- An existing test that is not listed in this plan starts failing and the fix would mean changing its assertion. In particular: if any existing test expects `.invalidCredentials` for a status other than 401, or expects a password to survive a failed Keychain read on the validation path, report it instead of editing the test.
- `applicationShouldTerminate` does not compile as written and the fix needs more than adding `@MainActor` to the method.
- Step 5's `Task { [self] in ... }` is rejected by the compiler and the fix needs anything other than changing the capture list.
- A step seems to need a change to `SettingsView.swift`, `ContentView.swift`, `ICloudHTTP.swift`, the stored credential format, or anything under `Scripts/`.
- Any verification would require typing an Apple ID password or a 2FA code into the running app. **HUMAN STEP**: that is never done by an agent.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- **Not verified against Apple.** "Only 401 is a wrong password" rests on the repo's existing tests, not on a live sign-in. If Apple answers a wrong password with another status, the manual sign-in shows "iCloud rejected the request (HTTP nnn)" instead of the wrong-password text. Silent re-auth then treats it as transient and keeps the session; the one-attempt guard (`lastAutomaticReauthenticationAt`, written before the password-bearing `signin/complete`) still stops repeated password sign-ins and their emails. A non-401 4xx on `signin/init` (which carries no password) is retried by the throttled refresh, at most every 5 minutes. A human who sees such a status in the log should add it to `rejection(status:)`.
- **SIGTERM is still not covered.** `Scripts/install-local.sh` and `Scripts/test.sh` stop the app with `pkill`, which does not call `applicationShouldTerminate`. A signal source that calls `NSApp.terminate(nil)` would close that gap but changes how long the app takes to die under those scripts; it belongs with plan 050 (scripts), not here.
- **Start Over on a first-ever sign-in** lands in `.needsReauthentication` ("Sign in to iCloud Again") even though nothing is stored, because it reuses `beginManualSignIn()`. It is cosmetic and clears on the next successful or failed sign-in or on Sign Out. Fix only if it is reported.
- **Sign Out in Settings** (`SettingsView.swift:174-186`) is still offered only when signed in. The sign-in window now offers it in `.needsReauthentication`; plan 048 owns the Settings row and its confirmation dialog and should treat both buttons alike.
- A wrong password typed into a failed manual sign-in stays in `pendingPassword` until the next attempt or Sign Out. Clearing it on failure needs a generation-checked catch in the public `signIn`; deferred as low value.
- Stored `webservices` written before this change are not re-checked on restore; they came from Apple over TLS and are replaced at the next validation.
- Reviewer focus: the order of `await stateWithoutSession()` and the generation guard in Step 4; that `pendingPassword` is still set when `submitTwoFactorCode` runs; that the 2-second timeout in Step 6 is acceptable at logout.
- Do not run `Scripts/install-local.sh run` as part of this plan unless the operator asks.
