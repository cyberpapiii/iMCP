---
title: A loopback connect can collide with a closing connection and wait forever
date: 2026-11-06
category: integrations
module: shared
problem_type: test_hang
component: network-framework
severity: medium
applies_when:
  - A test opens many short loopback connections, each to a new NWListener
  - An NWConnection is started without a timeout, or a test awaits an accept with no deadline
  - A CI job hangs in a test that connects twice in a row
tags:
  - network-framework
  - nwconnection
  - loopback
  - ci
  - flaky-test
---

# A loopback connect can collide with a closing connection and wait forever

## Problem

The macOS 27 CI job of run 42318303067 hung for 13 minutes in
`ServerNetworkManagerAuthTests.testDroppedConnectionLeavesNoPairingCodeTrust`.
It hung at the test's second connect. The app never logged "Handling new
connection", and the log's last lines were:

```
nw_socket_connect [C39:1] connectx(..., srcaddr=127.0.0.1:49178, dstaddr=127.0.0.1:49199 ...) failed: [48: Address already in use]
nw_endpoint_flow_failed_with_error [C39 127.0.0.1:49199 in_progress socket-flow ...] already failing, returning
```

The same code passed on the next run. The hang is intermittent.

## Cause

Each `LoopbackClient` opened a new `NWListener` on an ephemeral port. A new
listener can be given a port that an earlier client used, while the new
client is given that earlier connection's listener port. The two ports then
match a connection that has not finished closing (TIME_WAIT lasts 30 seconds
on macOS; on loopback the swapped ports count). connectx fails with
EADDRINUSE.

Network framework then holds the connection in `.waiting(EADDRINUSE)` and
never tries again. A local test waited 30 seconds and the connection did not
recover. `restart()` keeps the same local port, and so does a new
`NWConnection` to the same endpoint, often. The old helper started the client
with no state handler and awaited the listener's accept with no deadline, so
the test waited until the job timed out.

In a standalone loop of listener-plus-connect on this Mac, about one connect
in 700 to 3,000 collided. In each case the two ports had appeared earlier with
the roles swapped. One trace showed iteration 114 with listener 63913 and
client 64855, and iteration 658 with listener 64855 and client 63913.

In the test bundle the rate was much higher. The kernel hands out listener
ports and client ports from two counters that move in step (60898, 60899,
... and 59671, 59672, ...). After one swapped pair, the next pairs are
swapped too. A 150-iteration stress run of the socket tests, with a CPU load,
had about 100 unplanned collisions, up to nine in a row. Fourteen tests
failed even with three attempts, each on a new listener.

## Fix

- `NWConnection.startUntilReady` (`Shared/NWConnection+Async.swift`) treats
  `.waiting` with `NWError.isLocalAddressCollision` (EADDRINUSE) as final. It
  cancels the connection and throws at once. Before this, the CLI waited out
  its 15-second connect timeout and then reported that the connect had timed
  out.
- `LoopbackSocketPair` (`iMCPTests/Support/LoopbackSocketPair.swift`) opens
  every test socket on one listener for the whole run, and matches each
  accepted connection to its client by the client's port. A listener whose
  port never changes cannot be given a closing client's port. Every wait has
  a deadline, and a collision that still happens gets a new client.
- `StdinRecoveryTests` (`CLITests/CLIBootstrapTests.swift`), where the CLI's
  own `StdioProxy` is the client, stands the app in with one listener for
  the run too (`StandInApp`). The CLI test bundle does not compile
  `LoopbackSocketPair`, which needs the app's `withDeadline` and owns the
  client socket itself.
- `NWConnectionStartUntilReadyTests` makes the collision happen every time:
  it connects from the listener's port to an earlier client's port. With
  the old `startUntilReady`, it fails after the full 10-second timeout.

## Rule

Do not open a new `NWListener` for each test connection. Do not start a test
`NWConnection` without a timeout, or await an accept without a deadline. Use
`LoopbackSocketPair` in the app tests; in the CLI tests, keep one listener
for the run, as `StdinRecoveryTests` does.
