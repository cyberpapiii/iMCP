---
title: Find My Recovery Review Follow-ups - Plan
type: fix
date: 2026-11-10
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Find My Recovery Review Follow-ups - Plan

## Goal Capsule

- **Objective:** After the Mac has been asleep or offline, the Location tools come back without the owner signing in, and a network hiccup during that recovery never costs a sign-in prompt.
- **Means:** After Find My's page, iMCP tries two candidate sessions in a fixed order and treats an unanswered probe as unknown, not refused (KTD1, KTD2).
- **Authority:** This plan, then `AGENTS.md` for process and layout. The review receipt that raised these findings is input, not authority.
- **Stop conditions:** Stop if a change would let a second unattended password leave the Mac in one recovery episode, or if proving a change would need a live call to Apple.
- **Execution profile:** One pull request.
- **Who ships:** `Scripts/ship.sh`, as `AGENTS.md` "Finishing a change" defines.

## Product Contract

### Summary

Tighten the Find My recovery rung shipped in `27b6828..d40bf55` so that only a real refusal from Find My moves recovery forward, the session it saves is one the rest of the ladder accepts, the new rejection log line cannot carry a secret, and the Location window tests use the shared test clock.

### Problem Frame

A focused review of the shipped rung found four defects.
An unanswered first probe (a timeout or a 5xx) is handled like a refusal, so a working session is swapped out and the owner can be asked to sign in.
A session accepted from the page's jar is saved, yet the next rejection starts with `/setup/ws/1/validate`, which answered 421 for that jar on all three live runs on 2026-11-09.
The `Apple's reason:` log line prints server-supplied text as public.
`iMCPTests/LocationWindowModelTests.swift` adds a private clock double although `AGENTS.md` says to use the shared ones.

### Requirements

**Recovery after Find My's page**

- R1. A Find My probe that gets no session verdict never, by itself, leads to a sign-in prompt.
- R2. A page result with no service cookie skips only the candidate that needs that cookie.
- R3. When Find My accepts iMCP's own browser session with the page's service cookie, that session is the one saved.
- R4. A saved session that the setup service later rejects is renewed by one unattended trust-token sign-in. When Apple answers that sign-in with a verification-code request, or Find My refuses the renewed session, the owner is asked once and no second password is sent.
- R5. One recovery episode sends at most one unattended password, as `PasswordAttemptGuard` enforces today.

**Logging**

- R6. The rejection-reason log line shows only words from a known-safe set and replaces every other word.

**Tests and records**

- R7. The Location window tests take their time from the shared `TestClock`.
- R8. `docs/solutions/integrations/find-my-web-authorization.md` describes the rung as built.

### Scope Boundaries

- Not built: keeping the page's cookies across recovery runs so a later run can retry them. An immediate retry (KTD2) covers a blip. A longer outage ends in a pause that polls iMCP's own session; if Find My then refuses that session, the owner has to sign in, because the page's session is gone and the one unattended password is spent. Evidence that would change this: a live log showing both probes unanswered after the page succeeded.
- Not built: redacting the cookie names in the page-jar log line. Cookie names seen so far are fixed strings. Evidence that would change this: a name that embeds an account identifier.
- Not built: changing which rung follows a rejected `validate`. See KTD3.

#### Deferred to Follow-Up Work

- Reorder the ladder for page-accepted sessions once a live log line shows which candidate Find My accepts. Until then, a saved page session that the trust-token sign-in cannot renew needs the owner (R4).

## Planning Contract

### Key Technical Decisions

- KTD1. **Candidate order: own session with the service cookie first, the page's session second.** The setup service accepted iMCP's own session just before the page ran, so saving it should keep the next lapse on the narrow Find My page rung. That is a bet until a live log confirms it (see Assumptions). A refused first candidate costs one extra probe and nothing else. Today's order is the reverse.
- KTD2. **An unanswered probe is retried once at once, then counted as unknown.** The outcome over both candidates: any acceptance is live; every candidate refused runs the existing repair-or-sign-in check; anything else is "verification pending". The retry is immediate because the client has no injected sleep and the page finished network calls seconds earlier. Before returning "verification pending", reinstall iMCP's own cookies and client id, plus the page's service cookie when there is one, with no client-id write pending: the paused poll validates whatever jar is in memory, and the setup service rejects the page's.
- KTD3. **The ladder after a rejected `validate` stays as it is.** `recoverAfterRejection` already answers a 421 with the trust-token sign-in, which sends one password, the same count as the page rung. Which candidate Find My accepts is unproven, so reordering now would be a guess. A test pins the behavior (R4).
- KTD4. **Redact against an explicit allowlist.** Split the reason on whitespace and on `=`, `:`, `;`, `,` and quote characters. Keep a word only when, ignoring case and sentence punctuation at its ends, it is in a fixed list of diagnostic words or is exactly one of the cookie and header names the client already names in code. Replace every other word with one fixed marker. An unknown word of plain letters is replaced too, since letters alone do not make a value safe. The 120-character cap stays.
- KTD5. **`TestClock(start:)` replaces `WallClock.stopped(at:)`.** Its `wallClock` reads a fixed time until advanced, and its sleeps never fire unless a test advances it, which is what the three tests need.

### Assumptions

- Find My's verdict on a probe does not depend on an earlier refused probe in the same second.
- Apple's rejection strings are English prose plus cookie or header names, as the one seen live ("Missing X-APPLE-WEBAUTH-TOKEN cookie") is. The allowlist starts from that string and grows only from strings seen in logs.
- The setup service still accepts iMCP's own browser session after the page has signed in. The page may supersede iMCP's browser token; if it does, the saved own session gets a 421 at the next lapse and takes the R4 path. The first live log after a long sleep settles it.

## Implementation Units

### U1. Probe both candidate sessions and count unanswered probes as unknown

- **Goal:** Only a refusal from Find My moves past a candidate, and the saved session follows KTD1.
- **Requirements:** R1, R2, R3, R5, R8.
- **Dependencies:** none.
- **Files:** `App/Location/ICloud/ICloudAuthClient.swift`, `iMCPTests/ICloudSessionRenewalTests.swift`, `docs/solutions/integrations/find-my-web-authorization.md`.
- **Approach:**
  1. In `authorizeFindMyService`, build the candidates from the page result per KTD1; drop the first when the page returned no service cookie.
  2. Install each candidate's jar and client id, probe, and apply KTD2.
  3. Leave the generation check and `rejectedAfterPage` as the all-refused path.
  4. On "verification pending", restore iMCP's own session as KTD2 states before returning.
  5. Keep the cookie-name log lines; name the accepted candidate in the acceptance line.
  6. Rewrite steps 6 to 9 of the solutions entry to match, and correct its sentence that says which session Find My accepts "is unproven until the next 450".
- **Patterns to follow:** the existing `probe(_:disarmingPasswordGuard:)` and `FindMyProbe` cases; the scripted stubs in `ICloudSessionRenewalTests`.
- **Test scenarios:**
  - Own session accepted first: the saved client id is the stored one, the jar holds the old browser token and the page's service cookie, and no probe used the page's client id.
  - Own session refused, page's session accepted: the last probe carries the page's client id and the saved record adopts it.
  - First candidate answers 500 once, then 200: live, with no second candidate probed.
  - First candidate answers 500 twice, second refused: the state is "verification pending", not a sign-in request.
  - After that pending outcome, the next paused poll with `validate` 200 and Find My 200 ends live, requests no sign-in, and sends its requests under the stored client id.
  - First candidate refused, second answers 500 twice: "verification pending", and the jar in memory is iMCP's own session.
  - Both candidates refused, `validate` 421: a sign-in is requested and the page ran once.
  - Both refused, `validate` carries the repair cookie: the session pauses for account repair.
  - Page returns no service cookie: only the page's session is probed.
  - A second renewal in the same episode sends no second password.
- **Verification:** the renewal test class passes; the existing handover and second-try tests are updated to the new order, not deleted.

### U2. Pin recovery of a saved session the setup service rejects

- **Goal:** Prove R4 so a later ladder change cannot break it unnoticed.
- **Requirements:** R4, R5.
- **Dependencies:** U1.
- **Files:** `iMCPTests/ICloudSessionRenewalTests.swift`.
- **Approach:** Start from a stored record holding a page-shaped jar, then script Find My 450, `validate` 421, and the trust-token sign-in.
- **Test scenarios:**
  - Find My 450, `validate` 421, sign-in completes with the trust token: signed in, one `signin/complete`, Find My's page not run.
  - Same start, sign-in answers 409: a verification code is requested and no second password is sent.
  - Same start, sign-in completes but Find My answers 450 again: the session pauses for the owner, Find My's page is not run, and no second password is sent.
- **Verification:** the three scenarios pass against unchanged production code; if one fails, that is a finding to report, not a reason to change the ladder here.

### U3. Redact the rejection-reason log line

- **Goal:** The log line carries Apple's reason without any value that could be a secret.
- **Requirements:** R6.
- **Dependencies:** none.
- **Files:** `App/Location/ICloud/ICloudAuthClient.swift`, `iMCPTests/ICloudSessionRenewalTests.swift`.
- **Approach:** Apply KTD4 inside `rejectionReason(in:)`, so `send` logs only its result.
- **Test scenarios:**
  - "Missing X-APPLE-WEBAUTH-TOKEN cookie" comes back unchanged.
  - A reason containing a long mixed-case run with digits has that word replaced and the rest kept.
  - A reason containing an email-shaped word has that word replaced.
  - A reason containing an unknown word of plain letters has that word replaced.
  - A reason containing a cookie name joined to a value by `=` keeps the name and replaces everything after it.
  - A word that starts with `X-APPLE-` but is not a known name is replaced.
  - A body with `reason` but no `error` uses `reason`.
  - A body that is not JSON, or whose fields are not strings, gives nil.
  - A 300-character reason is cut to 120.
- **Verification:** the new cases pass and no log statement prints the raw body.

### U4. Use the shared test clock in the Location window tests

- **Goal:** Remove the private clock double.
- **Requirements:** R7.
- **Dependencies:** none.
- **Files:** `iMCPTests/LocationWindowModelTests.swift`.
- **Approach:** Build each of the three models with `TestClock(start: noonToday()).wallClock` and delete `WallClock.stopped(at:)`.
- **Test scenarios:** Test expectation: none -- the three existing tests are the proof and must pass unchanged.
- **Verification:** the Location window test class passes with `noonToday()` as the clock's fixed start.

## Verification Contract

| Check | Command | Applies to |
|---|---|---|
| Format gate | `Scripts/lint.sh --fix`, then `Scripts/lint.sh` | all units |
| Renewal tests | `Scripts/test.sh --only iMCPTests/ICloudSessionRenewalTests` | U1, U2, U3 |
| Location window tests | `Scripts/test.sh --only iMCPTests/LocationWindowModelTests` | U4 |
| Both suites | `Scripts/test.sh` | before shipping |

No check may call Apple. Live proof of KTD1 comes from the log after the next long sleep.

## Definition of Done

- R1 to R8 hold, each shown by a named test or by the edited document. R4 is shown against scripted Apple responses only.
- Both suites pass locally and in CI.
- `WallClock.stopped(at:)` is gone, and so is code from any approach tried and dropped during implementation.
- The solutions entry matches the code.
- The change is shipped through `Scripts/ship.sh`.
