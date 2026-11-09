---
title: A blocked Keychain call must not hold a Swift concurrency thread or a lock other items share
date: 2026-11-06
category: conventions
module: app
problem_type: test_hang
component: keychain
severity: high
applies_when:
  - Code calls SecItemCopyMatching, SecItemAdd, or SecItemUpdate from async code
  - A Task or Task.detached runs a call that can block on a Keychain prompt
  - Several Keychain-backed stores share one static lock
  - A test gates a fake Keychain read with a semaphore
tags:
  - keychain
  - swift-concurrency
  - cooperative-pool
  - ci
  - flaky-test
---

# A blocked Keychain call must not hold a Swift concurrency thread or a lock other items share

## Problem

The macOS 27 CI job of run 42324714297 hung in
`PairedClientStoreTests.testClientsSortNewestFirst`, inside `store.pair`.
The two tests before it said why:

```
PairedClientStoreTests.swift:340: error: -[... testAReadThatDoesNotAnswerInTimeIsUnavailable] : XCTAssertEqual failed: ("nil") is not equal to ...
Test Case '-[... testClientsIsNilWhenTheStoreCannotBeRead]' passed (10.127 seconds).
```

10.127 seconds is the 10 s Keychain read deadline (then
`PairedClientStorage.readDeadline`, now `KeychainItemQueue.promptDeadline`),
although that test's fake Keychain fails at once.

## Cause

Three faults, each enough for part of it:

1. The gated test signalled its gate once and then read again. The answered
   read could finish first, so the next call started a fresh read, which
   waited on the gate forever.
2. Every `PairedClientStorage` took one `static` lock around each Keychain
   call. The read blocked forever held it, so every later storage in the
   process, each over its own fake item, waited on it: reads until their
   deadline, writes for ever.
3. `DeadlinedValue` ran the read in `Task.detached`, and writes ran their
   read-modify-write in `Task.detached` too. The Swift concurrency pool has
   one thread per core and does not grow. A few blocked Keychain calls fill
   it, and then no task runs, the deadline timer that should release the
   caller included. With `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (a pool one
   thread wide) every gated-read test hung.

In the app, an unanswered Keychain prompt did the same: the blocked read
held a pool thread, and each paired-client write behind it held another
until the prompt was answered.

## Fix

`KeychainItemQueue` (App/Support) gives each Keychain item one serial
`DispatchQueue`, and every call to that item runs on it: deadlined reads,
deadlined read-modify-writes (`run(within:)`), and awaited calls with no
deadline (`perform`), which suspend the caller instead of blocking its
thread. Only `--icloud-status`, a one-shot command with nothing else to
run, blocks a thread (`loadBlocking`).
`DeadlinedValue` runs its read on a `DispatchQueue`. A blocked call then
holds up only later calls for the same item, and never a pool thread. A
write waits at most its deadline and fails. If it had not started by then
it never runs, so a write the caller was told failed does not land after
the prompt is answered.

## Rules

- Never run a call that can block on the user (a Keychain query, a
  semaphore wait) in a `Task`. Run it on a `DispatchQueue` and await the
  result.
- Serialize per resource, not per type. A `static` lock over instances of
  different items couples them. The queue belongs to the storage instance,
  so production builds one per item (`static let production`).
- An actor that awaits a Keychain call can run another of its calls in the
  meantime. Do a read-modify-write in one queued call, and check the
  actor's state (`ICloudAuthClient`'s auth generation) again before acting
  on the answer.
- A test that gates a fake read must clear the gate (`loadGate = nil`)
  before its last signal, or start every read it means to release before
  signalling.
- To find pool starvation, run with a one-thread pool. xcodebuild passes
  `TEST_RUNNER_`-prefixed variables to the test process:
  `TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 Scripts/test.sh --only iMCPTests/<Class>`.
  `DeadlinedValueTests.testBlockedReadsLeaveTheConcurrencyPoolFree` checks
  the same under the default pool.
