---
title: Repair Find My authorization without repeating full iCloud sign-ins
date: 2026-11-05
category: integrations
module: location-icloud
problem_type: integration
component: find-my-web-authorization
severity: high
applies_when:
  - iCloud validate succeeds while Find My returns HTTP 450
  - Full iCloud password sign-in creates repeated account emails
  - Find My stops working despite live browser cookies
tags:
  - icloud
  - find-my
  - authentication
  - webkit
  - keychain
---

# Repair Find My authorization without repeating full iCloud sign-ins

## Problem

Apple can keep the iCloud browser session valid while expiring Find My's separate authorization. In that state,
`/setup/ws/1/validate` returns 200 but `fmipservice/client/web/initClient` returns 450. A full SRP sign-in is the wrong
first recovery step: it creates an Apple account sign-in event and can send another email without restoring Find My.
The retired direct `accountLogin` password route returns 421.

The current iCloud web build is also not stable. Sending an old `clientBuildNumber` can produce the same 450, so a
cached build must be refreshed before escalating to a password-bearing operation.

## Solution

1. Read `clientBuildNumber` and `clientMasteringNumber` from `https://www.icloud.com/`, cache them, and retry one rejected
   Find My initialization with a forced refresh.
2. If the browser session validates but Find My still returns 450, load Apple's own `/find` page in a nonpersistent
   `WKWebView` instead of replacing the whole browser session. Seed only iMCP's Apple cookies, autofill the Keychain
   password, and wait for the `X-APPLE-WEBAUTH-FMIP` cookie.
3. Keep the WebKit view attached to a transparent, nonactivating on-screen panel. An unattached or off-screen view is
   background-throttled on macOS; Apple's SRP worker can stop after `signin/init` and never call `signin/complete`.
4. Persist the existing automatic-sign-in guard immediately before entering the password. Never retry the challenge
   after a relaunch until Find My accepts the session and clears the guard: a successful probe, or the first accepted
   call on the cached endpoints a launch restored without one.
5. Treat Apple's own page returning 403 from `signin/complete` as a rejected saved password for this narrower challenge.
   Stop immediately and request a manual sign-in.

6. Let Find My decide, not the setup service. After the page, `/setup/ws/1/validate` answered 421 on every live run,
   seconds after Find My had answered the page itself. So the session is not validated there: iMCP keeps the endpoints
   it already has and probes Find My directly.
7. Try iMCP's own browser session first, carrying only the `X-APPLE-WEBAUTH-FMIP` cookie the page earned, under iMCP's
   own client id. The setup service accepted that session just before the page ran, so if Find My takes it too, the
   saved session passes the next validation and the next lapse stays on this rung.
8. If Find My refuses that, try the page's session: the page's whole jar in place of iMCP's, under the page's own
   `clientId` (the script reports each of the page's `setup/ws/1` and `fmipservice` calls from iCloud's frames, and iMCP
   adopts the id of the last accepted one). The cookies are taken once Find My has answered the page, or eight seconds
   after the service cookie. A page that leaves no service cookie offers only this session.
9. Only a refusal moves on. A probe Find My does not answer (a timeout, a 5xx) is asked once more at once, and if it
   still has no answer it counts as unknown, never as refused.
10. Before anything else runs, put iMCP's own session back in memory. Every refusal then validates once: a terms or
    repair gate pauses; anything else asks for a sign-in, because the one automatic password attempt is spent. Any
    unanswered probe waits as "verification pending" instead. The paused poll validates whatever jar is in memory, and
    the setup service answers 421 to the page's, which is why the own session has to be the one left there.

A saved page session that the setup service rejects at the next lapse is renewed by the trust-token sign-in, which
sends one password. If Apple answers that with a verification code, or Find My refuses the renewed session, the owner
is asked once. Whether the page should run first for such a session waits on a live log.

Find My's authorization lapses when nothing polls it for roughly a quarter of an hour, as the web page's own idle
timeout does. A closed lid or an offline stretch longer than that ends in a 450 on the next call, so this rung runs on
most wakes and has to work unattended.

The WebKit data store is nonpersistent. Passwords remain in memory, decrypted cookies are copied only between in-memory
cookie jars, navigation is restricted to Apple HTTPS hosts, and no page body, field value, cookie value, or response body
is logged.

## Verification

- Fixture transport tests prove a 450 refreshes Apple's published build before authentication.
- Session tests prove a valid browser session uses the Find My challenge without calling the full `signin/complete`
  route in iMCP's auth client.
- A restart regression proves a failed password-bearing Find My challenge persists the one-attempt guard and cannot run
  again after process restart.
- A session test proves that Apple's own page refusing the saved password ends in a manual sign-in, with no paused
  polling of a password Apple has already refused.
- Live traces on 2026-11-09 (09:04, 12:54, 18:55) showed the page succeed and iMCP's replay fail: service cookie set,
  the page's own `refreshClient -> 200`, then `validate -> 421` from iMCP with the page's jar and client id. Each
  followed an offline stretch of twenty minutes or more. Session tests pin the two probes, their order, the retry of an unanswered
  probe, and the jar left in memory. Which session Find My accepts is unproven until the next 450; the log says
  `Find My accepted iMCP's own session with the page's service cookie` or `Find My accepted the page's session`, and
  `Find My page jar:` lists the cookie names the page added and dropped.
- Live trace on 2026-11-05 proved the state split: `/validate -> 200`, Find My `initClient -> 450`, Apple's own Find My
  page `signin/init -> 200`, then `signin/complete -> 403`. No full iMCP browser re-sign-in was needed to identify it.
