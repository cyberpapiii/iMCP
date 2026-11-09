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

6. Take the page's result whole. The page mints its own iCloud `clientId`, and Apple binds the session the page signs in
   to it: replaying the page's cookies under iMCP's id earns `validate -> 421`. The script reports each of the page's
   `setup/ws/1` and `fmipservice` calls (path, status, client id) from iCloud's frames; iMCP adopts the id of the last
   accepted call, stores it as the session's client id, and replaces its jar with the page's instead of merging into it.
7. Wait for the page's own Find My call to succeed before taking its cookies; the service cookie appears first. If that
   call never shows, take the cookies eight seconds after the service cookie.
8. If Apple still rejects the session after the page, ask for a sign-in. The one automatic password attempt is spent, and
   a paused poll of a session Apple dropped (`validate -> 421`) asks for a sign-in rather than polling forever.

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
- Live traces on 2026-11-09 (09:04 and 12:54) showed the page succeed and the session die after it: service cookie
  set, then `validate -> 421`, then "waiting for Find My verification" polled every five minutes until a manual sign-in.
  Session tests now pin the jar and client-id handover and the sign-in request on 421. The live handover is unproven
  until the next 450; its log lines are `Find My page call: ... -> status` and `Find My page finished: ...`.
- Live trace on 2026-11-05 proved the state split: `/validate -> 200`, Find My `initClient -> 450`, Apple's own Find My
  page `signin/init -> 200`, then `signin/complete -> 403`. No full iMCP browser re-sign-in was needed to identify it.
