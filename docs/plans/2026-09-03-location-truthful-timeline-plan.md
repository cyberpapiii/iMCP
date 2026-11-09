# Location: truthful timeline and durable sign-in

Date: 2026-09-03. Installed build under audit: commit `70c2e3c`, installed 17:46.

## Mental model

Four layers, each with one job:

1. **Auth** (`ICloudSession`, `ICloudAuthClient`, `ICloudCredentialStorage`).
   Holds an iCloud web session: SRP sign-in with a trust token, then
   `accountLogin` to get the Find My endpoint and a cookie jar. The jar, the
   tokens, the account endpoints, and the password live in one data-protection
   Keychain item. On launch the jar is replayed without any network call.
2. **Collection** (`LocationSampler`). Every 600 s asks Find My for the current
   user's iPhone (it does wake the phone: `locate: true`) and writes one row
   into the SQLite history. Nothing runs when the app is not running.
3. **Inference** (`LocationService.visits`). Groups a device's samples into
   clusters by distance and calls each cluster a visit.
4. **Presentation** (the `location_*` tools). JSON with coordinates, an
   address, arrival and departure.

## Confirmed root causes (from logs, the database, and the installed binary)

- **Auth: a renewed session Find My still rejects is treated as healthy.** After
  the reboot at 17:53 the app restored silently, then at 18:34:56 Find My
  answered 450. `refreshSession` ran `accountLogin`, Apple answered 200, the
  retry got 450 again, and the tool call failed. The same sequence repeated at
  18:45. Because `accountLogin` did not throw, the session stayed in
  `signedIn`, the menu showed nothing wrong, the password-based re-sign-in
  never ran, every sampler tick cost one more account login, and no samples
  were written. The stored-password path only fires on an *error* from
  `accountLogin`; the failure mode Apple actually produces is "200 but
  untrusted".
- **Auth: the client id is not persisted.** `ICloudSession` mints a new
  `clientID` per process and sends it on `accountLogin`, on every Find My
  URL, and as the OAuth state during sign-in. The trust token Apple issues is
  bound to the client that earned it. Across restarts this went unnoticed
  because the replayed jar made Find My calls without any account login
  (three fresh processes at 17:49 all got 200 that way). The first time a new
  process had to run `accountLogin` (after the 40-minute offline reboot), the
  trust token did not carry, so the session came back untrusted and Find My
  said 450. This is the mechanism pyicloud guards against by storing
  `client_id` with the session.
- **Inference: clusters never split on time.** Samples at 40.73388,-74.98696
  from 09-02 14:07 to 18:48, one at 09-03 10:36, and 16:58 to 17:49 were one
  cluster, reported as a 27-hour visit. The store had nothing in between.
- **Inference: departure is the last sample.** Every visit's `departure` is
  the last timestamp observed there, whether the next thing seen was movement,
  a gap, or nothing at all.
- **Inference: one-sample clusters pass the dwell filter.** The dwell check is
  on span, so a single outlier sample (09-01 08:25, 250 m from Home, 28 m
  accuracy) became the "brief stop near 713 Meridian Ave".
- **Presentation: no coverage or health.** The answer for a range with no
  data is an empty array, indistinguishable from "was nowhere".
- **Presentation: reverse-geocoded addresses read as destinations.** The
  address of the cluster centre is emitted as `address` with no qualifier.
- **Collection: the sampler comment says it does not wake the phone; the code
  does** (`locate: true, selectedDeviceID: phone.id`). The comment is wrong,
  not the code; the fresh fix is the point.

## Hypotheses, not confirmed

- Which `accountLogin` body flags (`hsaChallengeRequired`,
  `hsaTrustedBrowser`) Apple returned at 18:34. The body is not logged. This
  change logs both so the next occurrence answers it.
- Whether the 40 minutes offline (not the reboot itself) is what let the
  Find My cookie lapse server-side. Either way the fix is the same.

## Design (smallest coherent)

Auth:

- Persist `clientID` in `ICloudCredentials`. The auth client adopts the stored
  id on restore/refresh/reauthenticate and saves it on every persist.
  `FindMyClient` is built with the client's current id.
- `accountLogin` reads `hsaChallengeRequired`/`hsaTrustedBrowser`, logs them,
  and throws a session-invalidating error when Apple says a challenge is
  required.
- `performRefresh` proves the renewed session with one Find My call. A 450
  there is the dead-session signal and goes straight to the silent
  password re-sign-in; if the trust token has lapsed the state becomes
  `awaitingCode` and the menu says so.
- `--icloud-status` reports whether a client id is stored.

Inference (new pure module `VisitInference`):

- Drop samples with horizontal accuracy worse than 300 m.
- Split a cluster when the time since the previous sample exceeds
  3 × sampler interval (30 min), or the sample is more than 150 m from the
  cluster's running centroid.
- A visit needs at least 2 samples and the caller's minimum dwell.
- Each visit has `arrival`, `lastObserved`, and `endedBy`:
  `movement` (with `departedBefore`, the next sample's time), `coverageGap`,
  `queryBoundary`, or `ongoing`.
- Coverage gaps are every hole longer than the threshold, including the
  leading and trailing ones inside the requested range.

Presentation:

- `location_timeline` (new): one device, coverage, gaps, visits, health.
- `location_now` (new): the tracked phone's latest fix with device name, fix
  time, age, accuracy, staleness, place or "near" address, and auth/sampler
  health; falls back to the last recorded sample when Find My is unavailable.
- `location_visits` keeps its array shape. Additive fields: `lastObserved`,
  `endedBy`, `departedBefore`, `nearAddress`, `label`. `departure` is now
  only present when movement ended the visit (equal to `lastObserved`).
- Named places are the only definitive `place`. Everything else is
  `nearAddress` and a `label` that starts with "near".

Subtracted or consolidated:

- Clustering, centring, and most-moved-device selection leave
  `Location.swift` for `VisitInference.swift`.
- The wrong sampler comment.
- The "stale snapshot" explanation in the 09-02 plan no longer describes the
  live failure; this plan supersedes it for the auth part.

## Risks and open questions

- Apple may return `hsaTrustedBrowser: false` even on sessions Find My
  accepts. Only `hsaChallengeRequired: true` is treated as invalidating, and
  the Find My probe covers the rest.
- The trust token currently stored was earned by a client id that is gone.
  The first silent re-sign-in after this change may need a verification
  code once. After that the id is stored and the code should not be asked
  again until Apple's ~30-day trust lapses.
- Callers that read `departure` as always present get nil for ongoing and
  gap-ended visits. `lastObserved` is the replacement.

## Verification

1. `swift format`, lint, `Scripts/test.sh`.
2. Unit tests for: gap splitting, sampler stopping mid-visit, query ending
   mid-visit, movement-supported departure, low-accuracy samples, named vs
   geocoded places, 200-then-450 recovery, `hsaChallengeRequired`, client id
   reuse across sessions, stale fixes.
3. Install with `Scripts/install-local.sh run`. The live session is in the
   exact failing state (accountLogin 200, Find My 450), so launch exercises
   the fix: expect either a silent re-sign-in or a visible "code needed".
4. `--icloud-status` shows `client id: present` after the next persist.
5. Two sampler ticks write rows; quit and relaunch; rows keep coming with no
   account login in the log.
6. `location_timeline` for the last three days shows the 09-02/09-03 hole as
   a gap and no 27-hour visit.

## Outcome (2026-09-03 evening)

Implemented as designed. `Scripts/test.sh`: 368 tests, 0 failures (25 new
across `VisitInferenceTests`, `ICloudSessionRenewalTests`,
`LocationTimelineToolTests`; one existing readiness test updated because a
visit now needs two fixes). Installed with `Scripts/install-local.sh run`.

Live checks on the installed build (pid started 19:16:24, again 19:30:06):

- Launch restored the session from the Keychain with no `accountLogin`;
  `initClient` and `refreshClient` answered 200. `--icloud-status` shows
  `client id: present` after the first cookie write.
- Two sampler ticks (19:16:25, 19:26:42) answered 200 and rows with fix
  times 19:16:43 and 19:26:47 followed. Each tick's `locate` wakes the phone,
  whose fresh fix lands a few seconds after the tick has read the snapshot,
  so a tick typically records the fix its predecessor requested (rows are
  keyed on the fix time, see below).
- Quit and relaunch at 19:30: silent restore, no account login, first tick
  200. One sign-in has now survived three process starts.
- `location_timeline` for 09-01 to now: five gaps listed (1559, 113, 947,
  381, 77 minutes), the 163 Quarry St stay is 168 minutes ending in
  `coverageGap`, no visit crosses the 09-02/09-03 hole. `location_now`
  reports device, fix time, age, accuracy, staleness, health, and a "near"
  address.

Not verified live:

- The 200-then-450 recovery path. By install time Apple was accepting the
  stored session again (an account login at 19:06 from the previous build had
  refreshed the jar), so the probe found nothing to recover. The path is
  covered by tests; the next occurrence logs `accountLogin accepted:
  hsaChallengeRequired=…`.
- Reboot continuity. Not performed in this session; the same restore path is
  what the two relaunches exercised.

Found during verification:

- `Scripts/install-local.sh` kills the app early and the always-on watchdog
  relaunches the old bundle before the new dylib lands, so the first process
  after "Installed" can be the previous build. Relaunch once more after an
  install before trusting a live check. Not changed here (out of scope).
- The sampler records Apple's fix time and deduplicates on it. A tick that
  reaches Apple but gets an unchanged cached fix writes no row, so a phone
  that is genuinely still and not producing fixes will read as a coverage
  gap rather than as "still there". History shows the phone normally yields a
  fresh fix per tick (overnight 09-01: 50 rows in 486 minutes), and the
  30-minute threshold absorbs one missed tick, but recording "contacted,
  fix unchanged" as its own evidence would make gaps mean "no contact" and
  is the next improvement if this shows up in practice.

## Location window (2026-09-04)

Visibility was the missing piece: the tools were truthful but nobody could
see what they saw. `App/Views/LocationWindow.swift` adds a **Location…**
window off the menu: a MapKit map (solid track between fixes closer than the
gap rule, dashed spans across gaps labelled "no data 2h 10m", stay pins sized
by observed duration, the latest fix with its accuracy circle), a sidebar of
stays and gaps in time order with plain-word endings, a day picker with a
1/3/7-day span, click-to-name that writes `places` with `source = "manual"`,
a "Seen N times" badge for unnamed stays that recur across the last 30 days,
and a health strip (iCloud state, recording interval, last fix age, last
failure). The window is built on `LocationHistoryStore` and
`VisitInference` directly, so it and `location_timeline` cannot disagree.
Pure wording and drawing rules live in `LocationTimelineItems` and are
tested; a model test drives a real store through reload and naming.
Suite: 378 app tests pass. Installed 2026-09-04 10:39. Not verified: the
window on screen (display was dark during the check), so the first live look
is the user's.
