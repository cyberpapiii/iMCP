# Plan 036: Make the iMCP developer loop prompt-free and fast

> **Executor instructions**: Follow this plan phase by phase. Run every
> verification command and confirm the expected result before moving on. If
> anything in the "STOP conditions" section occurs, stop and report — do not
> improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 41aa951..HEAD -- .github/workflows/ci.yml Scripts/ install-local.sh iMCP.xcodeproj/project.pbxproj`
> If any of those changed since this plan was written, compare the "Current
> state" measurements below against a fresh run before proceeding.

## Status

- **Result**: DONE on 2026-08-31. Phases 1.1–1.4, 2.1–2.2, and 3.1–3.3 shipped.
  Step 2.3 was rejected after measurement because 324 app tests now execute in
  4.5 seconds and worker startup would target build/launch overhead, not the
  remaining test cost. Step 3.4 was rejected because asynchronous auto-merge
  cannot also install and verify the merged app before the command returns;
  `Scripts/ship.sh` keeps the reliable, fully automated blocking flow. Phase 4
  remains optional future work, not part of this completed P1 plan.
- **Priority**: P1
- **Effort**: M (phases 1–3) + L (phase 4, optional)
- **Risk**: LOW for phases 1–3; MED for phase 4
- **Depends on**: none
- **Category**: developer experience, tests, CI
- **Planned at**: commit `41aa951`, 2026-08-31

## Why this matters

Three costs dominate a day of work on iMCP, and all three are measured below
rather than assumed:

1. **The app test suite spends two thirds of its time on unoptimized
   big-integer arithmetic.** 320 tests take 65.5 s; roughly 45 s of that is
   SRP modular exponentiation running at `-Onone`.
2. **Every reinstall re-prompts.** Two of the four Keychain stores write to the
   file-based login keychain, whose access control is bound to the creating
   binary, and the Debug configuration signs ad hoc, so every build carries a
   new code identity.
3. **Shipping blocks the human for five minutes.** `Scripts/ship.sh` polls CI
   to completion before it merges and installs, so the developer waits on a
   run that GitHub is perfectly willing to merge on its own.

## Current state (measured at `41aa951`, 2026-08-31)

### Test and CI timing

| Step | Where | Time |
| --- | --- | ---: |
| `xcodebuild test -scheme iMCP` (320 tests) | local, warm build | 65.5 s test execution, 71.7 s wall |
| SRP sign-in tests within that suite (~17 tests × ~2.6 s) | local | ≈45 s (69% of the suite) |
| Cache restore | CI | 16 s |
| Lint | CI | 6 s |
| Build | CI | 54 s |
| Test CLI | CI | 35 s |
| Test app | CI | 167 s |
| Cache save | CI | 18 s |
| **CI total** | | **5 m 02 s** |

### The SRP cost, isolated

`App/Services/Location/SRPMath.swift` and `SRPClient.swift` compiled standalone
and run once, on this machine:

```console
$ swiftc -Onone -o srp_debug SRPMath.swift SRPClient.swift main.swift && ./srp_debug
init=1.193s proof=1.328s total=2.521s

$ swiftc -O -o srp_release SRPMath.swift SRPClient.swift main.swift && ./srp_release
init=0.004s proof=0.004s total=0.007s
```

**357× slower at `-Onone`.** `BigUInt` is a hand-written limb array
(`SRPMath.swift:12`), and unoptimized Swift pays bounds checks, retain/release,
and no inlining on every limb operation. This is not only a test cost: a real
iCloud sign-in from a Debug build stalls for the same 2.5 s.

### Signing and permissions

- Debug signs ad hoc: `"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-"`
  (`iMCP.xcodeproj/project.pbxproj:1036`), so every Debug build has a fresh
  cdhash. `Scripts/install-local.sh` compensates by re-signing the staged copy
  with a stable development identity and refusing an identity change that would
  reset TCC grants (`install-local.sh:78-104`). That guard works — it is the
  reason TCC grants survive today.
- The project carries two team identifiers: Debug `DEVELOPMENT_TEAM =
  R7AYS6Z734` and Release `DEVELOPMENT_TEAM[sdk=macosx*] = TTY35UM57S`.
  `ListenerEndpointFile` pins `TTY35UM57S`.
- Keychain storage is inconsistent:

  | Store | Data-protection keychain? |
  | --- | --- |
  | `App/Services/Location/FindMyPeopleBootstrap.swift:444` | yes |
  | `App/Services/Location/LocalStorageKeyStorage.swift:223` | partly (sets `kSecAttrSynchronizable`, not `kSecUseDataProtectionKeychain` on every path) |
  | `App/Services/Location/ICloudCredentialStorage.swift:283-327` | **no** |
  | `App/Controllers/PairedClientStorage.swift:275-315` | **no** |

  Confirmed on disk:

  ```console
  $ security find-generic-password -s "co.dododo.iMCP.paired-clients" | grep keychain:
      keychain: "~/Library/Keychains/login.keychain-db"
  ```

  Items in the login keychain are guarded by an ACL naming the creating binary.
  A re-signed or rebuilt app is a different binary, which is what produces the
  "iMCP wants to use your confidential information" prompts. It also explains
  the repeated iCloud sign-ins: when the credential item cannot be read, the app
  is signed out. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is ignored
  by the file keychain, so the intent expressed in that code is not the
  behaviour it gets.

### The test-host bundle identifier collision

`xcodebuild test -scheme iMCP` fails with `Could not launch "iMCPTests" ... The
LaunchServices launcher has returned an error` whenever `/Applications/iMCP.app`
is running, because the test host shares the identifier `co.dododo.iMCP`.

Overriding the identifier was measured and **works**: with
`PRODUCT_BUNDLE_IDENTIFIER=co.dododo.iMCP.tests`, the whole suite ran while the
installed app stayed running, and exactly one test of 320 failed —
`ListenerEndpointFileTests.testAppTestHostIsSignedAsIMCP`
(`iMCPTests/ListenerEndpointFileTests.swift:314`). That test asserts the
identity gate protecting the listener endpoint file, so the fix is **not** to
relax it. The identifier override is therefore rejected, and the plan removes
the collision by other means (phase 2, step 1 for the cheap fix; phase 4 for
the structural one).

## Out of scope, and why

**Granting TCC automatically is not possible on this machine and is not in this
plan.** Full Disk Access, Contacts, Calendars, Reminders, Photos, Location, and
Screen Recording live in SIP-protected TCC databases. `tccutil` can reset a
grant but never create one. The only supported way to pre-approve them is a
PPPC configuration profile delivered by an MDM to an enrolled Mac; a profile
installed by hand does not grant TCC. Anyone claiming otherwise is describing
either an MDM-enrolled Mac or a Mac with SIP disabled, and disabling SIP is
explicitly forbidden by `AGENTS.md` for this project.

What this plan does instead is make each grant a **one-time** event: keep the
code identity stable so the existing grants keep matching, and make the missing
ones obvious and one click away. That is the honest ceiling without MDM.

## Phase 1 — Stop the prompts

### 1.1 Sign Debug with the stable development identity — **done**

Landed as automatic signing under team `HJF7LN64XX` for the app and CLI targets
in Debug, with the test bundle signed the same way -- a test bundle whose team
differs from its host fails to load with "mapping process and mapped file
(non-platform) have different Team IDs". CI overrides all of it on the command
line and swaps in `App/App.CI.entitlements`. `install-local.sh` re-signs only
when the staged authority differs from the expected identity, and passes
`-allowProvisioningUpdates` so the profile that authorizes the keychain access
group is minted and embedded.


Change the Debug configuration to sign with `Apple Development` and the team
that owns the local certificate, instead of ad hoc. CI has no certificate, so CI
must keep the ad-hoc identity; pass it on the command line rather than changing
the default back.

- `iMCP.xcodeproj/project.pbxproj`: Debug `CODE_SIGN_IDENTITY[sdk=macosx*]` from
  `"-"` to `"Apple Development"`, `CODE_SIGN_STYLE = Automatic`, and reconcile
  `DEVELOPMENT_TEAM` with the team of the installed app's certificate.
- `.github/workflows/ci.yml`: append `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO`
  to the build and test invocations.
- `Scripts/install-local.sh`: once the build product is already correctly
  signed, the stage-and-re-sign block (lines 74-85) becomes a verification step
  rather than a mutation. Keep `verify-app-signing.sh` and keep the designated
  requirement comparison at lines 90-104 — that guard is what protects the TCC
  grants and must not be removed.

Verify:

```console
codesign -dv --verbose=4 .build/codex-derived-data/Build/Products/Debug/iMCP.app 2>&1 | grep Authority
# expect: Authority=Apple Development: ... , not "Signature=adhoc"
```

### 1.2 Move every Keychain item to the data-protection keychain — **done**

Landed as `App/Models/KeychainItem.swift`, one type replacing three
near-identical private implementations. It reads the data-protection keychain
first, migrates an item found only in the file keychain, and falls back to the
file keychain on `errSecMissingEntitlement` so an unentitled build (CI, or a
contributor with no certificate) still works. Verified on a real reinstall: no
prompt, no `-34018` in the log, and the migration notice for the iCloud
credentials.


Add `kSecUseDataProtectionKeychain: true` to every query, save, and delete in
`ICloudCredentialStorage` and `PairedClientStorage`, and to the paths in
`LocalStorageKeyStorage` that lack it. Items then live in the entitlement-scoped
keychain, where access is granted by code signature identity rather than a
per-binary ACL, and no prompt is ever shown.

Migration matters: an item written to the file keychain is invisible to a
data-protection query. Add a one-time read-old / write-new / delete-old step on
first launch, and keep it until a release has shipped with it.

- Write the migration so a failed read leaves the old item alone. Losing the
  paired-client store silently re-prompts every MCP client for approval.
- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` becomes meaningful here;
  keep it.

Verify:

```console
security find-generic-password -s "co.dododo.iMCP.paired-clients" 2>&1
# expect: "The specified item could not be found in the keychain."
# (the file keychain no longer holds it; the app still reads it)
```

### 1.3 Pre-authorize the code-signing key — **not needed so far**

No `codesign` keychain prompt appeared across the reinstalls done for 1.1 and
1.2, so the signing key's partition list already allows `codesign:`. Keep this
step for a machine where the prompt does appear; do not run it pre-emptively.


`codesign` prompts for Keychain access to the signing key unless the key's
partition list allows it. This is a one-time, per-machine command, so it belongs
in a setup script rather than in every developer's memory:

```console
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$LOGIN_KEYCHAIN_PASSWORD" ~/Library/Keychains/login.keychain-db
```

Put it in `Scripts/setup-dev-machine.sh` (new), prompt for the password
interactively, and never store it. Document that this is the one command in the
whole loop that legitimately asks for a password.

### 1.4 Add `Scripts/doctor.sh` — **done**

One command that reports, without changing anything:

- which signing identity `/Applications/iMCP.app` carries, and whether it
  matches the local certificate;
- whether the designated requirement matches the current build product;
- which TCC grants the app holds, probed the way `App/Models/FullDiskAccess.swift`
  already probes Full Disk Access — by attempting the access and reporting the
  result, never by reading the TCC database;
- whether the Keychain items are readable;
- whether the always-on agent is loaded
  (`launchctl print user/$UID/co.dododo.iMCP.always-on.agent`).

For anything missing, print the exact deep link, for example
`open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"`.
A grant still needs a human click; finding the right pane should not.

## Phase 2 — Local loop speed

### 2.1 One command to run the tests safely — **done** (`Scripts/test.sh`)

`Scripts/ship.sh:152-174` already knows how to run the app tests next to a
running install: SIGSTOP the `iMCPAlwaysOn` helper, kill the app, run, restore
both on exit. That logic is worth having on its own.

Extract it into `Scripts/with-app-stopped.sh` and have both `ship.sh` and a new
`Scripts/test.sh` call it. One implementation, one place to fix.

Verify: with `/Applications/iMCP.app` running and the always-on agent loaded,
`Scripts/test.sh` completes and the app is running again afterwards.

### 2.2 Compile the SRP math optimized in Debug — **done**

`SRPMath.swift` and `SRPClient.swift` moved to a local Swift package,
`Packages/SRP`, whose target carries `.unsafeFlags(["-O"], .when(configuration:
.debug))`. Swift optimizes per module, so the split is what makes the setting
possible. The API the app and the tests use is now `public`; nothing else about
the math changed.

Measured, not projected:

| Step | Before | After |
| --- | ---: | ---: |
| `ICloudSRPTests` (11 tests) | 7.879 s | 0.225 s |
| `testProofMatchesReferenceVector` (3 modular exponentiations) | 2.605 s | 0.066 s |
| App suite | 61.2 s / 320 tests | 4.3 s / 324 tests |

An attempt to get the same win without the module split failed and is worth
recording: rewriting the CIOS inner loops on unsafe buffer pointers bought about
11%, and `@_optimize(speed)` bought nothing, because `-Onone` runs no optimizer
pipeline for the attribute to configure. The cost is the un-inlined
`multipliedFullWidth` and `addingReportingOverflow` calls, and only a real `-O`
module removes them.

`ICloudSRPTests` still checks both proofs against the `cocagne/pysrp` reference
vector byte for byte, and passes unchanged.

### 2.3 Turn on parallel test execution — **rejected after measurement**

The suites are independent per class. Add `-parallel-testing-enabled YES
-parallel-testing-worker-count 4` to the local and CI test invocations, or mark
the test targets parallelizable in the shared schemes.

Do this **after** 2.2, and measure separately. Parallelism over a suite that is
69% one serial bottleneck mostly hides the bottleneck instead of removing it.

With 2.2 landed the app suite runs in 4.3 s, so the remaining wall-clock is
build and launch overhead rather than test execution. Measure before adding
worker processes; this step may no longer be worth its complexity.

## Phase 3 — Pipeline

### 3.1 Build once, test twice — **done**

CI currently builds in the `Build` step, then builds again inside each of the
two `test` steps. Replace with:

```console
xcodebuild build-for-testing -scheme iMCP -destination "platform=macOS" ...
xcodebuild test-without-building -scheme imcp-serverTests -destination "platform=macOS"
xcodebuild test-without-building -scheme iMCP -destination "platform=macOS"
```

### 3.2 Split the cache — **done**

The current key hashes `**/*.swift`, so every source change misses the exact key
and falls back to a prefix restore, while still paying 18 s to save a new copy
each run. Use two caches: `~/Library/Caches/org.swift.swiftpm` keyed on
`Package.resolved` (changes rarely, hits almost always), and DerivedData keyed
on `**/*.pbxproj` with the existing prefix restore-keys.

### 3.3 Cancel superseded runs — **done**

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

### 3.4 Stop waiting for CI locally — **rejected; conflicts with verified install**

Replace `ship.sh`'s CI polling loop with GitHub's own auto-merge:

```console
gh pr merge "$pr_url" --auto --merge --delete-branch
```

Requires auto-merge enabled on the repository and a branch protection rule on
`main` requiring the CI check — without the required check, `--auto` merges
immediately and the gate is gone. Set both up before making this change, and
verify with a deliberately failing PR that it does **not** merge.

`ship.sh` then returns as soon as the PR is open, and gains `--wait` for the
cases where the developer wants the old blocking behaviour. The local install
step moves to a separate `Scripts/land.sh` (or `ship.sh --wait`), because there
is nothing to install until the merge happens.

## Phase 4 — Structural (optional, larger)

Extract the host-independent code — everything under `App/Models/`,
`App/Shared/`, and the pure parts of `App/Services/` — into a local Swift
package that both the app target and a host-free test target depend on. That
removes the test host entirely, so:

- the LaunchServices collision disappears without weakening any identity check;
- unit tests run without launching an app;
- the SRP target from phase 2.2 becomes an ordinary package target with
  per-target `swiftSettings`.

This is a real refactor with real risk, and the phases above deliver most of the
benefit without it. Do it only if the loop still feels slow afterwards.

## STOP conditions

- The designated-requirement comparison in `install-local.sh:90-104` fails, or
  any step proposes removing it. That guard is the reason TCC grants survive.
- Keychain migration cannot read an existing item. Stop with the old item
  intact rather than losing paired clients or the iCloud session.
- `ListenerEndpointFileTests` or `ICloudSRPTests` fail. Those are the identity
  and math gates for phases 1 and 2.
- Any step requires disabling SIP, editing a TCC database, or entering a
  password other than the one-time login-keychain unlock in 1.3.

## Verification checklist: a prompt-free build → install → run cycle

Run this from a clean state, twice in a row. The second pass is the one that
matters, because the first can legitimately ask for grants that were never
given.

**Setup, once per machine**

- [ ] `Scripts/setup-dev-machine.sh` completes; the login-keychain password is
      asked for exactly once and never stored.
- [ ] `Scripts/doctor.sh` reports every TCC grant present, or deep-links the
      panes for the missing ones.

**The cycle**

- [ ] `Scripts/test.sh` runs both suites to green with `/Applications/iMCP.app`
      running and the always-on agent loaded, and leaves the app running.
- [ ] `Scripts/install-local.sh run` completes with no `codesign` password
      prompt.
- [ ] No "iMCP wants to use your confidential information stored in ... in your
      keychain" dialog appears at any point.
- [ ] No "iMCP would like to access your Contacts / Calendar / Reminders /
      Photos / Location" dialog appears.
- [ ] No Full Disk Access prompt appears, and `browser_history_search` and
      `calls_fetch` still return data.
- [ ] The app is still signed in to iCloud: `location_friends` returns without
      an authentication error.
- [ ] Previously paired MCP clients reconnect without a new approval dialog.
- [ ] The always-on agent is loaded afterwards:
      `launchctl print user/$UID/co.dododo.iMCP.always-on.agent` exits 0.

**The pipeline**

- [ ] `Scripts/ship.sh -m "..."` returns in under 60 s with a PR URL and
      auto-merge armed.
- [ ] A PR whose CI fails does **not** merge.
- [ ] CI wall time is at or under 3 minutes.
- [ ] `Scripts/doctor.sh` after the merged change installs reports the same
      grants as before it.

**Numbers to record when the phases land** (replace the projections above with
measurements)

- [x] App suite: 65.5 s → 4.5 s (324 tests, measured 2026-08-31)
- [x] CI total: 5 m 02 s → 3 m 21 s (successful run 33445465167)
- [ ] `Scripts/ship.sh` blocking time: ≈5 min → ______
