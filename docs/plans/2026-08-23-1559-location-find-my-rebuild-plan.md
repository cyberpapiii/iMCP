# Rebuild Location on the iCloud Find My web API

> **Superseded in part (noted 2026-10-12).** This is the original design
> record and is kept as written. Three things below no longer hold. (1) The
> Apple ID password **is** persisted: by owner decision it is always stored
> in the this-device-only data-protection Keychain item alongside the session
> tokens, with no opt-in. The statements under "Settled decisions", unit B
> "Persistence", and the forbidden list that it is never persisted are
> historical. (2) The D4 renames did not ship; the tools are
> `location_places` and `location_place_set`. (3) Location now declares 12
> tools, not seven. Current behaviour is described in `README.md` under
> "iCloud sign-in and location history".

**Status** — Priority: high · Effort: large (5 units) · Risk: high (unit B) · Depends on: nothing · Category: feature

## Why this matters

`location_current` reads this Mac's own CoreLocation position at kilometre accuracy and returns it under a name that an agent reads as "where is the user". The answer is "where is this Mac". An agent asking it is not merely imprecise, it is confidently wrong, and a confidently wrong answer about someone's whereabouts is worse than no answer at all.

This replaces the service with one sourced from Find My, so "where is the user" is answered by the device the user is actually carrying, and adds the history layer Apple exposes nowhere.

## Settled decisions

The twelve decisions in the intake brief are constraints, not open questions. Two are load-bearing enough to restate:

- **No fallback.** The Mac's CoreLocation source is deleted. Location is unavailable until the user signs in to iCloud. There is no degraded mode, because a degraded mode reintroduces the exact tool this work exists to delete.
- **The agent never handles credentials.** The user signs in through the app's own window. Session and trust tokens go to the Keychain. The password is never persisted and never touched by an agent.

## Research corrections

Two claims surfaced during research were checked against source and one was wrong. Both are recorded because the wrong one would have changed the design.

**Corrected — Find My does not require a stored password.** Research reported that `fmipservice` is re-auth-gated such that a background poller "must keep the raw password in the Keychain", citing pyicloud's `_authenticate_with_credentials_service`, which posts `{"appName": "find", "apple_id", "password"}`. That function exists but Find My does not reach it. In `timlaing/pyicloud@main` (pushed 2026-08-17), `pyicloud/services/findmyiphone.py:80-97` handles the auth failure as:

```python
except PyiCloudAuthRequiredException:
    if retry is True:
        raise
    self._server_ctx = None
    self.session.service.authenticate(force_refresh=True)
    self._refresh_client_with_reauth(locate=locate, retry=True)
```

`authenticate` is called with no `service` argument. Its password branch at `pyicloud/base.py:356-361` is guarded by `service is not None`, so it is skipped. Control reaches `_authenticate()` (`base.py:533-541`), which tries `_authenticate_with_token()` first — a POST of `session_token` plus `trustToken` to `/setup/ws/1/accountLogin` — and only falls through to `_srp_authentication()` (which needs the password) when that fails.

**Consequence:** session token plus trust token are sufficient for unattended Find My polling. Settled decision 11 stands unmodified. The password is needed only when the trust token itself expires, which is the re-authentication case already flagged as an open area.

**Confirmed — Family Sharing devices are returned; Find My People is not.** `findmyiphone.py:169` sends `"fmly": self._with_family` in `clientContext`, and `_initialize_devices` (`:103-141`) polls `userInfo.membersInfo[*].deviceFetchStatus == "LOADING"` until family members resolve. The separate Find My Friends (`fmfWeb`) endpoint stopped returning data in April 2023 and has no working replacement short of GrandSlam/anisette auth. `location_people` is therefore built from family *devices*, which is what decision 10 already assumes.

## Design decisions this plan makes

These are decisions the intake brief left open or stated in a form the codebase cannot support.

### D1 — All seven tools are declared statically; sign-in state is reported at call time

The brief says that when signed out, Location's "tools are not exposed". The codebase cannot do that cheaply, for three independent reasons:

1. `ToolBuilder` (`App/Models/Service.swift:19-24`) implements only `buildBlock(_ tools: Tool...)`. There is no `buildOptional`, `buildEither`, or `buildArray`, so `if signedIn { Tool(...) }` does not compile inside a `tools` body.
2. The tool-definition cache (`App/Controllers/ServerNetworkManager.swift:44-45`, `684-703`) is built on the first `ListTools` of the process and has no reset path anywhere in the repo. `plans/012-cache-tool-definitions.md` states the assumption in prose: definitions are static for a build, only the enablement filter changes at runtime.
3. Nothing outside the actor can currently invalidate it, because `services` is captured at actor init.

Making the tool set vary with sign-in state means new builder methods, new cache invalidation driven from outside the actor, and a `notifyToolListChanged` broadcast on every sign-in and sign-out. That is a large change to shared connection machinery in service of a marginal gain.

**Decision:** declare all seven statically. A signed-out call returns a typed error whose message names the fix. The service toggle still gates exposure entirely — Location toggled off means no Location tools, which is the existing, working mechanism.

**This is a deviation from the brief's stated target shape and should be reviewed as such.**

### D2 — `LocationServiceError` joins the sanitized-error allowlist

`App/Controllers/ToolErrorResponse.swift` is eleven lines and collapses every error except `FetchPolicy.Error` into `"Tool execution failed. See iMCP logs for details."` Under D1 that would turn "not signed in to iCloud" into an opaque failure, which defeats D1 entirely.

Add a `LocationServiceError` enum with a small closed set of cases — `notSignedIn`, `sessionExpired`, `rateLimited`, `deviceUnavailable` — and allow its `errorDescription` through, exactly as `FetchPolicy.Error` is allowed through today. The cases carry no paths, no NSError domains, and no server payloads, so the trust boundary holds.

An agent needs to tell "no data" from "not permitted" from "temporarily failed" and say something different to the user in each case. This is what makes that possible.

### D3 — The Mac never silently backs a person's row

The failure being deleted can walk straight back in. If the user's most recent fix happens to come from this MacBook because the phone has not reported recently, `location_people` reproduces `location_current` exactly: "you are at home" because the *Mac* is at home.

**Rule:** when selecting which device backs a person's row, prefer phone and watch classes. Never silently fall back to the device whose `thisDevice` flag is true. When no non-Mac fix exists, the row's `status` is `noFix` rather than a Mac-derived position, and `device.isThisDevice` is surfaced on every row regardless so an agent can hedge.

### D4 — Two tools are renamed from the brief

- `location_places` becomes **`location_named_places`**. As written it collides with `maps_search` and `maps_explore`, which also return places. An agent asked to find a pharmacy nearby could plausibly call `location_places`, receive Home and Office, and report that there are no pharmacies.
- `location_place_set` becomes **`location_name_place`**. Nothing else in the repo is `noun_verb`; every mutating tool reads `reminders_create`, `contacts_update`, `shortcuts_run`. It also describes the operation more honestly, since it both creates and renames.

### D5 — SRP is implemented in-repo, not added as a dependency

Apple's SRP-6a needs `rfc5054_enable()` and `no_username_in_x()` semantics — `x = H(salt ‖ H(":" ‖ password))` with no username, RFC5054 padding on. `adam-fowler/swift-srp` is stock SRP-6a and would need forking for this, and it pulls `adam-fowler/big-num`, a BoringSSL `BIGNUM` wrapper.

The repo has never added an SPM dependency for app code, `AGENTS.md` explicitly discourages adding packages, and the fork would be ours to maintain anyway. A minimal fixed-width 2048-bit modular exponentiation plus the SRP-6a exchange is self-contained, testable with published vectors, and adds no supply chain.

CryptoKit covers SHA-256 and HMAC. PBKDF2 comes from CommonCrypto's `CCKeyDerivationPBKDF`, which is already on the platform.

**If unit B's SRP proves harder than budgeted, falling back to a vendored fork of `swift-srp` is the escape hatch — flag it rather than sinking days.**

### D6 — `coverage` ships on `location_history` and `location_visits`, always

The single worst answer this surface can produce is a fabricated false negative about another person's movements. Find My returns current position only; a family member's visit history exists only from the moment iMCP started logging. Asked "when did Jess leave work last Tuesday" against a store that started Thursday, an empty result is indistinguishable from "she went nowhere", and the agent will say the latter.

Both tools return `coverage: { earliestSample, latestSample }` on the envelope unconditionally, so the agent can compare it to the requested range and say "I only have data since Thursday."

## Current state

| Fact | Evidence |
|---|---|
| Location reads this Mac only | `App/Services/Location.swift:12` sets `kCLLocationAccuracyKilometer`; `:345` calls `requestLocation()` |
| Only Maps depends on LocationService | `App/Services/Maps.swift:60`, `:66` |
| Cycling is available in the SDK | `MKDirectionsTypes.h:14`, `API_AVAILABLE(macos(11.0))` |
| App is not sandboxed | `iMCP.xcodeproj/project.pbxproj:765`, `:831` — `ENABLE_APP_SANDBOX = NO` |
| Zero HTTP client exists | no `URLSession` match anywhere in `App/` or `CLI/` |
| Zero SQLite writes exist | all four consumers open `SQLITE_OPEN_READONLY` |
| Tool names must stay globally unique | `iMCPTests/CallToolDispatchTests.swift:9-13` |
| Service identity is the class name | `App/Controllers/ServiceRegistry.swift:71` — `String(describing: type(of: service))` |

## Scope

**In:** `App/Services/Location.swift` (rewritten), `App/Services/Maps.swift`, `App/Controllers/ServiceRegistry.swift`, `App/Controllers/ToolErrorResponse.swift`, `App/Models/Service.swift` (deactivate hook), new files under `App/Services/Location/`, `App/Views/` (sign-in window), `AGENTS.md`, `README.md`.

**Out:** Find My items and AirTags, Find My People, lost mode, erase, geofence and push alerting, any pattern or summary tool, an iPhone Shortcut bridge.

## Implementation units

Each unit builds, verifies, and commits before the next. Unit B is the risky one and the only one that cannot be verified without the user present, so everything landable without it lands first.

### Unit A — Delete CoreLocation, decouple Maps, move geocoding, add cycling

No network, no credentials, fully verifiable by the agent.

1. Delete `App/Services/Location.swift` in full.
2. `App/Services/Maps.swift`: remove the `isActivated` and `activate()` overrides at `:57-67` so Maps takes the protocol defaults.
3. Move geocoding into Maps as `maps_geocode` and `maps_reverse_geocode`, porting the `CLGeocoder` bodies from the deleted file. Note this incidentally fixes the repo's only hyphenated tool name.
4. Add `cycling` to `mapsTransportType(from:default:)` (`Maps.swift:32-48`) and to the `enum:` arrays at `:188` and `:372`. Add `"any"` to `maps_eta` for parity with `maps_directions`. Note in both descriptions that cycling directions are unavailable in many regions and return an error rather than an estimate, so an agent comparing modes does not report "biking isn't possible" when the truth is "Apple has no bike data there".
5. `ServiceRegistry.swift`: remove the Location descriptor; set Maps' `permissionGuidance` to `nil`. **Maps then disappears from the Permissions settings tab**, which filters on `permissionGuidance != nil` (`SettingsView.swift:56`). That is correct — Maps no longer needs a permission — but it is a visible UI change, not an accident.
6. Remove `INFOPLIST_KEY_NSLocationAlwaysAndWhenInUseUsageDescription` and `...WhenInUseUsageDescription` from both configurations (`project.pbxproj:788-789`, `:858-859`). The app no longer requests Location Services at all.
7. Amend `contacts_me`'s description: its postal address is the highest-probability wrong answer once `location_current` is gone, since an agent finding no location tool will read the home address off the contact card. Add that addresses there are stored home and work addresses, not where anyone currently is.

Verify: `swift format -i -r .`, Debug build clean, both test targets green, and `CallToolDispatchTests` still passes with the renamed tools.

### Unit B — iCloud auth client and sign-in UI

The risky unit. Requires the user's hands.

1. **HTTP layer.** A dedicated `URLSession` with a non-shared `HTTPCookieStorage`. Implement `urlSession(_:task:willPerformHTTPRedirection:)` and return `nil` for auth calls: `Set-Cookie`, `scnt`, and `X-Apple-Session-Token` arrive on 302s and automatic redirect following hides them. This is the pitfall that costs people days.
2. **SRP-6a** per D5. Group NG_2048, SHA-256, RFC5054 padding, no username in `x`. Password preparation: `SHA256(password)`, hex-encoded as ASCII first when the server answers `protocol: "s2k_fo"`, then `PBKDF2-HMAC-SHA256(·, salt, iteration, 32)`.
3. **Sign-in flow.** `POST /appleauth/auth/signin/init` → `/signin/complete?isRememberMeEnabled=true` → 2FA (`/verify/trusteddevice/securitycode` or `/verify/phone/securitycode`) → `GET /2sv/trust` → `POST https://setup.icloud.com/setup/ws/1/accountLogin`. Capture `X-Apple-ID-Session-Id`, `X-Apple-Session-Token`, `X-Apple-TwoSV-Trust-Token`, `scnt`, `X-Apple-ID-Account-Country`. Echo `scnt` and the session id on every 2FA-step request.
4. **Persistence.** Session token, trust token, account country, and the `X-APPLE-WEBAUTH-TOKEN` / `X-APPLE-WEBAUTH-USER` cookies to the Keychain. Never the password. Follow `PairedClientStorage` exactly: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `SecItemUpdate` then `SecItemAdd` on `errSecItemNotFound`, and treat only `errSecItemNotFound` as empty — a transient Keychain error must never be read as absence and must never fall through to overwriting live state.
5. **Bound every Keychain read.** `SecItemCopyMatching` blocks indefinitely while macOS waits for an authorization prompt. Commit `08d26ce` cost 21 consecutive connections to exactly this. Reuse `OneShotSignal` and a deadline; do not invent a new waiter.
6. **Test seam.** Copy `PairedClientStorage.init(keychainLoad:keychainSave:)`'s closure injection so tests never touch the real Keychain. For HTTP, a `URLProtocol` stub — no precedent exists, this is new infrastructure.
7. **Sign-in window.** There is no `.sheet` anywhere in the repo and `LSUIElement = YES` means there is no window to attach one to. Follow `PairClientWindowController` (`App/Views/PairClientWindow.swift:4-33`): an `NSWindowController` hosting a SwiftUI view, held by `ServerController` or it deallocates.
8. **Trust expiry.** The trust token lasts roughly 30 days. Sign-in is not a one-time event. When it expires the poller stops and the service surfaces a re-authentication state; it must not silently return empty results.

**The user's hands are required here and nowhere else.** The user enters their Apple ID, password, and 2FA code into the app's own window. The agent must never type, read, or store any of the three. Everything downstream of this step is unverifiable until the user has signed in once.

### Unit C — `location_people`, `location_devices`, `location_ring`

1. `POST {findme}/fmipservice/client/web/initClient` then `refreshClient`, with `?dsid=`. Body per `findmyiphone.py:158-190`: `clientContext` with `appName: "iCloud Find (Web)"`, `appVersion: "2.0"`, `apiVersion: "3.0"`, `deviceListVersion: 1`, `fmly: true`, `timezone`, `inactiveTime: 0`. Echo `serverContext` back, nulling `theftLoss`. Never hardcode the `p<NN>-fmipweb` partition; read it from `webservices.findme.url`.
2. Family devices resolve asynchronously. Poll while any `userInfo.membersInfo[*].deviceFetchStatus == "LOADING"`, but **stop as soon as a retry makes no progress** — members with location sharing off stay LOADING forever, and a naive loop burns the full retry budget on every call.
3. `location_people` response per D3 and the shape below.
4. `location_devices` with optional `refresh`, which sets `shouldLocate: true` and `selectedDevice: "all"` and polls until `isLocating` clears.
5. `location_ring` → `POST {findme}/fmipservice/client/web/playSound` with `{"device": id, "subject": "Find My iPhone Alert", "clientContext": {"fmly": true}}`. Requires an explicit `deviceId` from `location_devices`; **no fuzzy name matching**, so a mistaken match cannot sound an alarm in someone's meeting. Reject any device not owned by the user.

`location_ring` is the first non-read-only tool in the codebase. Annotate `readOnlyHint: false`, `destructiveHint: true`. All seven get `openWorldHint: true` — the old `location_current` used `false` because CoreLocation is local, and that annotation would be a lie here.

**Response shape, `location_people`.** Envelope carries `retrievedAt` so ages are anchored. Per row:

- `status`: `located` | `noFix` | `notShared`. Never omit a person and never throw when one person has no location — omitting means the agent silently answers for three of four people or claims someone is not in the family.
- `isMe`, `name`, `personId`.
- `geo: { latitude, longitude }` **and** `address`. Both. Coordinates because every downstream tool takes flat lat/lon and that is what makes the bike-vs-car scenario a single hop; address because the human answer is "she's on Valencia St".
- `place: { name, id, source }`, present only on a confident match. **Only set it when the accuracy circle falls inside the geofence** — at 3 km accuracy "she's at the office" is a guess dressed as a fact.
- `accuracyMeters`, `locatedAt` (ISO 8601), `ageSeconds` (integer). Both time forms: ISO for convention, `ageSeconds` because agents do not reliably know "now" and get date subtraction wrong. No prose "12 minutes ago" field — it goes stale inside a conversation and gets quoted verbatim.
- `device: { name, id, model, isThisDevice }`.

### Unit D — Sampler, SQLite store, history, visits, named places

1. **Store.** `~/Library/Application Support/iMCP/`, already created at `0700` by `ListenerEndpointFile` (`App/Shared/ListenerEndpointFile.swift:84-107`). No security-scoped bookmark — the app is not sandboxed and this is its own directory. `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE`, WAL, plus schema creation and a version pragma. Follow the raw `sqlite3_` idiom in `CallHistory.swift:226-328`, including the `SQLITE_TRANSIENT` shim and null-checking every column read.
2. **Write serialization.** An actor owning the handle. The existing read-only stores need none of this; a polling writer plus concurrent tool-call readers does.
3. **Retention.** Pruning with a documented window. Nothing in the repo grows a file over time; this is the first thing that does.
4. **Poller.** `Task` + `while` + `Task.sleep`, stored in a cancellable property, cancel-before-reassign, `[weak self]`, and never swallow the sleep's cancellation — the three existing loops (`ServerNetworkManager.swift:105-137`, `MCPConnectionManager.swift:80-110`, `ServerController.swift:99-115`) all follow this and all have comments explaining why. Guard on `XCTestConfigurationFilePath` so it never runs under test, as `publishListenerEndpoint` does.
5. **Lifecycle.** `Service` has no `deactivate()`, so toggling a service off currently notifies nothing. Add one with a default no-op and stop the poller from it. This is the same shape as the battery-drain defect in `plans/006-fix-location-concurrency.md`: a singleton that starts work in `init` and never deinits.
6. **Backoff.** Never re-run `signin/init` on a schedule. `503` from Apple is throttling, not a wrong password; back off exponentially. Repeated failed SRP attempts lock the Apple ID.
7. **Tools.** `location_history` (with `limit`, defaulting bounded — every fetch tool in the repo has one and an unbounded range would blow out context), `location_visits` (defaulting to 7 days, with `minDurationSeconds`), `location_named_places`, `location_name_place`. Use `App/Models/FetchPolicy.swift` for the date range rather than hand-rolled parsing.
8. **Visit rows.** `place` or `null` with `geo` and `address` still populated so unnamed stops are not dropped; `arrival` and `departure` with local UTC offset preserved, not Z-normalized, because "when did Jess leave work" is a local-time question; `durationSeconds` as an integer so "how much time at the office last week" is a sum rather than fourteen error-prone subtractions; `ongoing: true` with `departure: null` for the current stay; `sampleCount`. Oldest first.
9. `location_name_place` is a write even though "places" reads as configuration — renaming Home retroactively changes how every past visit is labelled. `readOnlyHint: false`, `destructiveHint: true`, and say so in the description.

### Unit E — Docs

`AGENTS.md` Key paths (not `CLAUDE.md`, which stays a three-line pointer per `docs/solutions/conventions/agents-md-is-source-of-truth.md`), README service table, and a `docs/solutions/` entry for the Keychain-prompt-hang class and the register-a-service checklist.

## Verification

Per unit: `swift format -i -r .`, Debug build, both test targets.

```
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"
xcodebuild test -scheme iMCP -destination "platform=macOS"
```

**Quit `/Applications/iMCP.app` before the app-test gate.** Both share bundle id `co.dododo.iMCP` and the run fails with `IDELaunchErrorDomain` code 20 otherwise. Do not run it against a live `plug` session either — the test host advertises Bonjour and writes the listener endpoint file, so clients connect to it and lose the session when tests exit.

**Prefer adding cases to existing test files.** `iMCPTests/` is not a synchronized group; a new file needs four hand-edits to `project.pbxproj` (`PBXBuildFile`, `PBXFileReference`, group children, Sources phase). Three test files sat unrun for months because this was missed. Verify with `grep -c <BaseName> iMCP.xcodeproj/project.pbxproj` expecting `4`.

Behavioural checks worth writing:

- Ask "where am I" against the full tool list with `location_current` gone. Assert the agent calls `location_people` and specifically does *not* answer from `contacts_me`'s postal address.
- Fixture where the user's only recent fix comes from this Mac. Assert the answer is hedged or attributed, never asserted as the user's position. This is D3's regression test.
- `location_visits` over a window predating logging. Assert "I don't have data that far back", not "she went nowhere". Run once with `coverage` present and once absent to confirm the field carries the behaviour.
- "How long to X by bike vs car vs subway" with no hints. Assert one `location_people` call and three `maps_eta` calls, no invented distance tool. This is the proof the primitives are right.
- Four error fixtures — signed out, not sharing, empty store, rate-limited — producing four materially different sentences.

## Risks

**Apple breaks this.** Not hypothetical. Apple made SRP mandatory around late 2024; `picklepete/pyicloud` (2.8k stars, the canonical client) never recovered, and Home Assistant's iCloud integration has been broken from then through at least February 2026. The `fmfWeb` endpoint died in April 2023 and was never restored. Assume roughly annual breakage, and assume it can be a protocol change rather than a field rename — SRP was a rewrite plus a new bignum dependency, not a patch. There is no fallback by design (decision 2), so a breakage takes the feature fully offline.

**Terms of service.** These clients sit outside Apple's agreements. Observed enforcement is throttling and Apple ID lockout after repeated failed auth, not account termination; no verified instance of a ban for using this API was found, but that is an absence of evidence.

**Trust expiry is a recurring UX event**, not a one-time setup, and the design must treat it that way.

**Signing and TCC.** Keychain items are ACL'd to the signing identity, and the prompt keys on the binary's cdhash, so every local rebuild re-prompts unless installed through `Scripts/install-local.sh` with the stable "Plug Local Signing" identity. A changed signature can make a stored session token unreadable — which is exactly the hang condition step B5 guards against.

**`tools/list` payload.** Cold start to a usable tool list is a tracked number, currently ~62ms, of which ~28ms is serializing 26 tool schemas into 21 KB. Seven new tools grow that. Write terse descriptions and lean schemas. Note the ~20ms decode leg is a known upstream swift-sdk regex defect, not iMCP — do not re-diagnose it as new.

## STOP conditions

- A Keychain write that deletes or overwrites a real item on a transient error.
- Any code path that persists the user's Apple ID password.
- Any agent-initiated entry of a password or 2FA code.
- A required identity pin that rejects the Debug test host or `Scripts/install-local.sh`.
- Reintroducing a Mac-CoreLocation position anywhere in the Location surface, including as a fallback.
- A tool name colliding with an existing one.
