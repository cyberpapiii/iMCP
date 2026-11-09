---
title: A test listener that advertises an undeclared Bonjour type fails a few milliseconds after it is ready
date: 2026-11-06
category: integrations
module: app
problem_type: test_hang
component: network-framework
severity: medium
applies_when:
  - A test starts an NWListener with a `service` in the iMCP test host
  - A test waits for a listener to stay `.ready`, or for a replacement to become ready
  - A CI job hangs in NetworkDiscoveryManagerTests
  - The log shows "Server failed: -65555: NoAuth"
tags:
  - network-framework
  - nwlistener
  - bonjour
  - ci
  - flaky-test
---

# A test listener that advertises an undeclared Bonjour type fails a few milliseconds after it is ready

## Problem

The macOS 26 CI job of run 42330424740 hung for 14 minutes in
`NetworkDiscoveryManagerTests.testAnUnexpectedCancelIsReplacedWithAFreshListener`.
The last lines were:

```
Server ready and advertising via Bonjour on port 55930
Server failed: -65555: NoAuth
Attempting to recover from unexpected listener cancellation
Server ready and advertising via Bonjour on port 55931
Server failed: -65555: NoAuth
```

Green runs show the same first `NoAuth` in that test. Only the second one
is new.

## Cause

The test listeners advertised `_imcp-test._tcp`, so that they would not
compete with the running app's `_mcp._tcp`. The test host is the app, and
its Info.plist declares only `_mcp._tcp` in `NSBonjourServices`. macOS
accepts the listener and reports `.ready`. Then, 0 to 12 ms later, it
fails the listener with `-65555 NoAuth` (`kDNSServiceErr_NoAuth`). It
does this every time, on this Mac as well as on CI. A listener that
advertises `_mcp._tcp`, or no service, stays ready.

Each test passed only if it finished within those few milliseconds. When
a listener failed first, `NetworkDiscoveryManager` correctly waited out
its recovery delay. The tests use a `TestClock`, and most of them never
advance it, so the delay never ended. The test helpers waited on the
manager's change stream with no deadline. In the CI run, the replacement
listener failed 12 ms after it was ready, before the test had read the
state.

Under CPU load and `TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, 300
iterations of the class hung 3 times locally, in three different tests.

## Fix

- The tests build listeners that do not advertise
  (`makeUnadvertisedListener`). `testTheListenerAdvertisesTheIMCPService`
  checks the service that production's `NetworkDiscoveryManager.makeListener`
  sets, without starting the listener.
- Every wait in `NetworkDiscoveryManagerTests` fails after 10 s. On a
  timeout it finishes the change stream, so the abandoned wait ends too.
- `testAFailureReportedWithAnUnexpectedCancelIsReplacedOnceWithoutTheDelay`
  plays back the order CI saw (a failure, then the cancel). The cancel
  replaces the listener at once, and the failure's recovery is called off.
- `Scripts/test.sh` turns on XCTest's per-test timeouts (one minute) for
  both suites. A hang now fails its test, and xcodebuild restarts the test
  process and goes on with the next test. Before this, a hang used up the
  CI job's 15 minutes.

After the fix, 500 iterations (4,000 tests) under the same load passed.

## Rule

In the app test host, do not start an `NWListener` that advertises a
Bonjour type the app does not declare. Do not advertise `_mcp._tcp` from
a test either. Test listeners that only need a port should not advertise.
A test that waits for a real listener's state needs a deadline.
