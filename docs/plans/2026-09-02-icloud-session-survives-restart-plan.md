---
title: Keep the iCloud session alive across app restarts and reboots
date: 2026-09-02
artifact_contract: ce-unified-plan/v1
artifact_readiness: done
execution: code
---

# Keep the iCloud session alive across app restarts and reboots

> **Decision (noted 2026-10-12).** Kept as written. R5 and U3 describe an
> off-by-default "Keep me signed in" checkbox and a separate Keychain item
> `co.dododo.iMCP.icloud-password`. Neither exists: by owner decision the
> Apple ID password is always stored in the same this-device-only
> data-protection Keychain item as the session tokens, with no checkbox. The
> Status section below records the implementation.

## Goal Capsule

Stop the daily "sign in to iCloud again". A session that is alive when the app quits must still be alive when the app comes back, and when Apple does reject it the app must recover without a human wherever that is possible, and say exactly why when it is not.

## Evidence (2026-09-02)

- Location history (`location-history.sqlite`, provider `find-my-web`) shows continuous 10-minute samples from 2026-08-30 09:06 through 2026-09-01 12:07, then nothing. The Mac rebooted at 2026-09-01 13:16 and the app relaunched at 13:17. `location_devices` today returns "Not signed in to iCloud".
- Earlier daily gaps (2026-08-23 through 2026-08-29) line up with reinstall days: 8, 10, and 25 installs on 08-23, 08-24, and 08-29. Every reinstall restarted the app; before `cba2d0e` (2026-08-31) every reinstall also lost the file-keychain ACL.
- An app restart on 2026-08-31 18:34 (last install of the day) did *not* lose the session; samples continue through 23:51. The reboot two days later did. The difference is the age of the persisted snapshot, not reboot versus restart.
- The unified log kept no `services.location*` lines for the last 10 days, so the exact rejection at 13:17 is unrecorded. The app also cannot report *why* it is signed out: `FindMyError.notSignedIn` covers `signedOut`, `needsReauthentication`, and `credentialsUnreadable` alike.

## Root cause (verified in code, inferred for the Apple side)

1. `ICloudHTTPClient` uses an ephemeral `URLSession`; Apple's rolling cookie renewals from every Find My call land only in memory.
2. `ICloudAuthClient.persist` is the only writer of `ICloudCredentials`, and it runs only inside `accountLogin`. While the app stays up the session is renewed every 10 minutes by the sampler, but the Keychain snapshot stays frozen at sign-in time.
3. On relaunch `restore()` replays that stale snapshot. `restoreCookies` drops cookies that have expired, the first Find My call gets 421/450, `refreshSession` runs `accountLogin` with the equally old `dsWebAuthToken`, Apple rejects that too, and `invalidate()` sets `needsReauthentication`.
4. Nothing in the app can recover from step 3 without the password, because the password is never stored (by design, R4 of the 2026-08-28 plan).

## Requirements

- R1. The Keychain snapshot tracks the live session: whenever the iCloud cookie jar changes after a successful service call, it is persisted (rate-limited, no network cost, no email).
- R2. Restore succeeds silently from a snapshot that was live when the app last ran, across app restart and reboot.
- R3. When Apple rejects the stored session, the app logs the HTTP status and the step that failed at a level that persists, and the menu says which of "expired", "unreadable", or "never signed in" applies.
- R4. A read-only status report is available from the command line (`iMCP --icloud-status`, mirroring `--always-on`): state, snapshot age, cookie names with expiry, whether `dsid`/`webservices` are present. No token values, no account name.
- R5. Optional, user-decided: "Keep me signed in" stores the password in the this-device-only data-protection Keychain and re-runs the SRP sign-in with the trust token when token login fails. Off by default; the plan's other units do not depend on it.
- R6. Existing tests and injected seams remain source-compatible. No test touches the real Keychain.

## Implementation Units

### U1. Persist the live cookie jar (R1, R2)

Files: `App/Services/Location/ICloudAuthClient.swift`, `App/Services/Location/FindMyClient.swift`, `App/Controllers/ICloudSession.swift`, `App/Services/Location/ICloudCredentialStorage.swift`, `iMCPTests/ICloudAuthFlowTests.swift`.

- Add `ICloudAuthClient.persistCookiesIfChanged()` that re-reads the transport jar, compares to the stored `cookies` (name, value, expiry), and rewrites the credentials with the new jar and the same tokens. Also refresh `sessionToken`/`trustToken` if `state.absorb` saw new ones.
- Call it from `ICloudSession` after every successful `FindMyClient` call (sampler and tools both route through the session; add a `noteServiceCallSucceeded()` hook), throttled to at most once per 5 minutes and always on `applicationWillTerminate`.
- Tests: jar change persists; unchanged jar does not write; throttle respected; persisted snapshot restores and replays the newest cookies.

### U2. Say why, and keep the evidence (R3, R4)

Files: `App/Controllers/ICloudSession.swift`, `App/Services/Location/ICloudAuthClient.swift`, `App/Models/AlwaysOnCommandLine.swift` (pattern), new `App/Models/ICloudStatusCommandLine.swift`, `App/Services/Location.swift`, `App/Views/ContentView.swift`, `Scripts/doctor.sh`.

- `ICloudSession` records `lastInvalidationReason` (enum: `findMyRejected(status)`, `accountLoginRejected(status)`, `trustExpired`, `credentialsUnreadable(OSStatus)`, `networkUnreachable`) and logs it at `.error` so the unified log keeps it.
- `FindMyError.notSignedIn` message carries the reason.
- `iMCP --icloud-status` prints the report from R4 and exits; `Scripts/doctor.sh` calls it.

### U3. Silent re-sign-in with a stored password (R5) — needs Rob's decision

Files: `App/Services/Location/ICloudCredentialStorage.swift` (separate Keychain item `co.dododo.iMCP.icloud-password`), `App/Services/Location/ICloudAuthClient.swift`, `App/Controllers/ICloudSession.swift`, `App/Views/ICloudSignInWindow.swift`, `App/Views/SettingsView.swift`.

- Checkbox on the sign-in sheet: "Keep me signed in (stores your password in this Mac's Keychain)". Default off.
- On `refreshAccount` failure with 421/450, if a password is stored, run `signIn(accountName:password:)` with the stored trust token. A 2FA demand at this point means the trust token is gone; surface `needsReauthentication` as today.
- Sign-out deletes the password item first.
- Update the 2026-08-28 plan's R4 wording and `docs/find-my-people-setup.md` to describe the opt-in.

## Status (2026-09-02)

U1 and U2 are implemented, formatted, built, and tested (332 app tests, 56 CLI tests, all green), and installed via `Scripts/install-local.sh run`. Steps 1 through 3 of the contract are done except the sign-in itself, which needs Rob. Steps 4 and 5 are open until a fresh sign-in has run through two sampler ticks.

Two things learned while verifying:

- The snapshot in the Keychain from 2026-09-01 00:33 still had 17 cookies with expiries in October, and Apple rejected it anyway (`initClient` 450, `accountLogin` 421). Cookie expiry dates say nothing about whether the server still honors the session; only a snapshot that tracks the live jar does.
- `--icloud-status` first ran the whole app: `@StateObject` initializers execute before `init()`, so the status process started the sampler, called Apple with the stale jar, and got the session rejected. `App.init` now runs the command-line checks before it creates the server controller, and the status process makes no network calls.

U3 is implemented with Rob's go ("I care about my user experience"): the password is kept in the same data-protection Keychain item as the tokens, `ICloudAuthClient.reauthenticate()` re-runs the SRP sign-in with the stored trust token, and `ICloudSession` calls it whenever Apple rejects the stored session or the 30-day trust guess elapses. While Apple honors the trust token the sign-in completes with no code; once it lapses the session stops at `awaitingCode` and the menu asks for the code. Sessions signed in before this change have no password on file and need one more manual sign-in.

## Verification Contract

1. `swift format -i -r .` then `swift format lint --strict --recursive .`
2. `Scripts/test.sh`
3. `Scripts/install-local.sh run`, sign in once, wait for two sampler ticks, then `iMCP --icloud-status` shows a snapshot younger than 10 minutes.
4. Quit and relaunch the app: state is `signedIn` with no network sign-in (no accountLogin line in `log stream`).
5. Reboot the Mac: same as 4. This is the acceptance gate for the reported bug.

## Risks and Stop Conditions

- Stop U1 if Apple's Find My responses never rotate cookies (then the stale-snapshot theory is wrong and the rejection must be found from U2's logs first).
- Do not implement U3 without an explicit go from Rob; it reverses a documented security decision.
