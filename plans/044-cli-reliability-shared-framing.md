# Plan 044: Make the CLI deliver the last reply, never reconnect mid-session, and share one frame scanner with the app

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` (if a row for 044 exists) — unless a reviewer
> dispatched you and told you they maintain the index.
>
> **Start from an up-to-date `main`** (`git fetch origin && git switch -c
> advisor/044-cli-reliability-shared-framing origin/main`). Plans 037 and 043
> must already be merged.
>
> **Drift check (run first)**:
> `git diff --stat 7b80094..HEAD -- CLI/ CLITests/ App/Controllers/NWConnectionTransport.swift App/Shared/ iMCPTests/NWConnectionTransportTests.swift iMCP.xcodeproj/project.pbxproj AGENTS.md`
> Plans 037 and 043 are expected to show up here (043 edits the
> challenge-answering block in `CLI/StdioProxy.swift` and how
> `CLI/MCPService.swift` passes the pairing code). For every file listed,
> compare the "Current state" excerpts against the live code. Line numbers
> may have shifted; that is fine. If the *shape* of an excerpt is gone (a
> function this plan edits no longer exists, or already has the target
> shape), treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED for steps 1–4; HIGH for step 5 (separable; the plan is
  complete and valid if you stop after step 4)
- **Depends on**: plans/037-isolate-tests-from-real-state.md,
  plans/043-connection-pairing-security.md
- **Category**: bug, tests, tech-debt
- **Planned at**: commit `8165d29` (branch `feat/menu-bar-resilience`),
  2026-10-12. All `CLI/` and `CLITests/` excerpts are from `origin/main` at
  `7b80094`, which has one extra commit touching `CLI/`.

## Why this matters

`imcp-server` is the stdio proxy every MCP client talks through. Three
defects make it hang or lose data, and none is covered by a test because
`CLI/StdioProxy.swift` is not compiled into the CLI test target:

1. When the app's last reply and its connection close arrive in the same
   read, the CLI throws the reply away. The client waits for an answer that
   was delivered and dropped.
2. When the connection ends after the client's `initialize` has already been
   read from stdin, the CLI silently opens a new connection. Stdin is not
   replayed, so the new session never sees `initialize` and the client hangs.
   The project rule is: never reconnect mid-session in the CLI.
3. After the CLI launches the app, it waits on Bonjour for up to 30 s (plus a
   5 s back-off) without looking at the endpoint file the app writes about a
   second later.

Separately, the app and the CLI each carry a hand-copied version of the same
wire-frame scanner, with a comment in each saying it mirrors the other. Step 5
replaces both with one.

The fixes are mostly subtraction: the initialize-reply sniffing, the
`.connectFailed` error case, and ~60 lines of duplicated scanning go away.

## Current state

Files and roles:

- `CLI/StdioProxy.swift` (653 lines) — actor that pumps bytes between
  stdin/stdout and the app's TCP socket. Not in the test target.
- `CLI/MCPService.swift` (301 lines) — discovery and the reconnect loop.
  Not in the test target, and it must stay out: `run()` calls
  `NSWorkspace.openApplication` and a real `NWBrowser`.
- `CLI/CLIBootstrap.swift` (262 lines) — pure decision functions, already in
  the test target. `StdioProxyError` lives at the bottom.
- `CLI/MessageFrameScanner.swift` (160 lines) — `MessageFrameScanner`
  (network → stdout framing), `MCPInitializeCompatibility`,
  `StdinFrameScanner` (stdin → network framing).
- `CLI/main.swift` (40 lines) — top-level code; defines the globals `log`,
  `defaultIOBufferSize`, `serviceType`, `parameters`. Cannot be compiled into
  a test bundle.
- `App/Controllers/NWConnectionTransport.swift` (312 lines) — the app end of
  the same socket; `receiveLoop` holds the duplicate scan.
- `App/Shared/` — files compiled into both the app and the CLI
  (`AuthPreamble.swift`, `ListenerEndpointFile.swift`, `OneShotSignal.swift`,
  `ResumeGate.swift`).
- Tests: `CLITests/CLIBootstrapTests.swift`,
  `CLITests/MessageFrameScannerTests.swift` (two `XCTestCase` classes in one
  file: `MessageFrameScannerTests` and `StdinFrameScannerTests`),
  `iMCPTests/NWConnectionTransportTests.swift`.

### Defect 1: reply dropped when it arrives with the close

`CLI/StdioProxy.swift:538-553`:

```swift
            do {
                let (data, isComplete) = try await receiveNetworkChunk(
                    from: connection,
                    bufferSize: bufferSize
                )

                if isComplete {
                    await log.debug("Network connection complete")
                    throw peerCloseError()
                }

                if data.isEmpty {
                    continue
                }

                let messages = frameScanner.consume(data)
```

`data` is discarded whenever `isComplete` is true. The app end already does it
in the right order: `App/Controllers/NWConnectionTransport.swift:193-250`
scans the buffer, then `:252-261` handles `isComplete`.

### Defect 2: reconnect after stdin was consumed

`CLI/StdioProxy.swift:151-153` and `:335-337`:

```swift
    /// Set when a successful initialize result has been forwarded to stdout.
    /// A peer close before that is a connect failure the CLI can retry.
    private var didCompleteInitialize = false
```
```swift
    private func peerCloseError() -> StdioProxyError {
        stdioProxyErrorAfterPeerClose(didCompleteInitialize: didCompleteInitialize)
    }
```

`peerCloseError()` is thrown at seven places in `StdioProxy.swift`
(`:341, :422, :429, :522, :529, :546, :641`). `:602-605` sets the flag by
JSON-parsing every message until one looks like an initialize reply.

`CLI/CLIBootstrap.swift:225-262`:

```swift
enum StdioProxyError: Swift.Error, Equatable {
    case connectionClosed
    case stdinClosed
    case connectFailed
    /// One message exceeded the stdin limit. Terminal: reconnecting would
    /// resume mid-message and send the app garbage.
    case stdinFrameTooLarge
}

func stdioProxyErrorAfterPeerClose(didCompleteInitialize: Bool) -> StdioProxyError {
    didCompleteInitialize ? .connectionClosed : .connectFailed
}

func mcpMessageIsSuccessfulInitializeResult(_ message: Data) -> Bool { ... }
func mcpMessageIsInitializeHandshakeReply(_ message: Data) -> Bool { ... }
```

`CLI/MCPService.swift:70-98` (inside `run()`):

```swift
                } catch let error as StdioProxyError {
                    if Task.isShuttingDownGracefully { return }
                    // StdioProxyError retries from loopback-first.
                    // Only `.connectionClosed` / `.stdinClosed` end the process.
                    discoveryMode = .preferLoopback
                    switch error {
                    case .connectFailed:
                        await log.info("Connection closed before initialize, will retry...")
                        try await Task.sleep(for: .seconds(1))
                        continue
                    case .connectionClosed: ... return
                    case .stdinClosed: ... return
                    case .stdinFrameTooLarge: ... return
                    }
                } catch let error as NWError {
                    if Task.isShuttingDownGracefully { return }
                    guard case .posix(let code) = error, code == .ENOTCONN || code == .ECONNRESET
                    else {
                        throw error
                    }
                    await log.critical("Network connection terminated: \(error), shutting down...")
                    return
                }
            } catch {
                ... // lines 99-118: pick discoveryMode, log, sleep 5 s, loop again
```

The question that decides "retry or exit" is not "did initialize complete"
but "has this process taken bytes off stdin". Stdin is created per proxy
(`CLI/StdioProxy.swift:417-419`, `standardInputStream`) and anything read is
gone. Two paths reconnect after stdin was consumed today: `.connectFailed`
(client sent `initialize`, app closed before replying), and the outer generic
`catch` (for example a send that fails with `EPIPE` is an `NWError` that is
not `ENOTCONN`/`ECONNRESET`, so it is rethrown into the 5 s retry).

### Defect 3: Bonjour wait ignores the endpoint file

`CLI/MCPService.swift:197-225`:

```swift
    private func discoverEndpointViaBonjour() async throws -> NWEndpoint {
        let loopbackInspection = lastLoopbackInspection
        await launchAppIfNotRunning()
        await log.info("Starting Bonjour service discovery...")
        ...
        return try await withCheckedThrowingContinuation {
            continuation in
            let resumeGate = ResumeGate()

            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(30))

                if await resumeGate.shouldResume() {
                    let notice = CLIBootstrap.bonjourTimeoutNotice(
                        loopbackInspection: loopbackInspection
                    )
                    await log.error("\(notice)")
                    ...
                    browser.cancel()
                    continuation.resume(throwing: MCPError.internalError(notice))
                }
            }
```

It has three callers, all in `resolveEndpoint(mode:)` (`:176, :190, :193`),
each written `return .bonjour(try await discoverEndpointViaBonjour())`. The
`:190` caller is the `.skip` branch: the endpoint file was unusable when
inspected (usually: app not running yet). `DiscoveryMode.bonjourOnly` (`:193`)
is set after a loopback connect *failed*; the comment at `:41-43` explains
that the endpoint file must not be retried in that mode or a stale file loops
forever.

### Duplicate scanner (step 5)

`CLI/MessageFrameScanner.swift:30-90` and
`App/Controllers/NWConnectionTransport.swift:160-262` run the same sequence:
strip complete `AuthResponseFrame`s, break on a partial one, disconnect on a
rejected one, break on a partial `AuthChallengeFrame`, strip heartbeats, break
on a partial heartbeat, then scan incrementally for a newline. The real
differences, which step 5 must preserve:

- The app awaits `authResponseHandler` for a response frame **before** any
  later message from the same read is yielded
  (`NWConnectionTransport.swift:194-212`), and clears `authChallenge` so the
  handler runs once.
- The app closes the connection if its buffer exceeds 1 MB
  (`NWConnectionTransport.swift:177-183`). The CLI has no cap.
- The CLI strips complete challenge frames and stashes them
  (`MessageFrameScanner.swift:36-40`, `drainAuthChallenges()` at `:87-90`).
  The app does not strip them at all.

`AuthChallengeFrame` and `AuthResponseFrame`
(`App/Shared/AuthPreamble.swift:60, :121`) are both `Equatable, Sendable`.

### Test target wiring

`imcp-serverTests` compiles CLI sources straight into the test bundle (no
host app). Its Sources phase is `B53F67B71CE8E2EB7B5CB823` in
`iMCP.xcodeproj/project.pbxproj` (~line 635) and lists `MessageFrameScanner`,
`OneShotSignal`, `BonjourEndpointSelection`, `AuthPreamble`,
`ListenerEndpointFile`, `CLIBootstrap`, `ClientKeyStore`. `StdioProxy.swift`
and `ResumeGate.swift` are absent. `CLI/` and `App/` are synchronized groups,
so a file there joins its own target with no pbxproj edit; anything compiled
into a *second* target needs explicit entries. The exemplar for a shared file
in the CLI target is `ResumeGate.swift`:

```
B02900010000000000000001 /* ResumeGate.swift in Sources */ = {isa = PBXBuildFile; fileRef = B02900020000000000000002 /* ResumeGate.swift */; };
B02900020000000000000002 /* ResumeGate.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; name = ResumeGate.swift; path = ../App/Shared/ResumeGate.swift; sourceTree = "<group>"; };
```

plus a child line in the `CLITests` group (`9784E568F0621136136A0EAC`) and a
line in the CLI Sources phase `F8F44EB22D5908D00075D79C`.

### Conventions

- Swift, warnings are errors, deployment target macOS 15.1.
- Decisions are extracted as pure static functions on `CLIBootstrap` and
  tested directly. Exemplar: `CLIBootstrap.appLaunchDecision`
  (`CLI/CLIBootstrap.swift:183-193`) and its tests
  (`CLITests/CLIBootstrapTests.swift:246-284`). Match it.
- `log` is main-actor isolated; every call is `await log.<level>(...)`.
- Local Xcode is 27 beta and adds the diagnostics `ImplicitStrongCapture` and
  `NoUseUnstructuredThrowingTask`; CI is Xcode 26. If either fires on a line
  you wrote, copy the form already used at `CLI/StdioProxy.swift:128-131`
  (`Task { [weak self] in try? await ... }`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| CLI tests | `Scripts/test.sh --cli-only` | all pass |
| One CLI class | `Scripts/test.sh --cli-only -only-testing:imcp-serverTests/<Class>` | all pass |
| App tests | `Scripts/test.sh --app-only` | all pass |
| One app class | `Scripts/test.sh --only iMCPTests/NWConnectionTransportTests` | all pass |
| Both suites | `Scripts/test.sh` | all pass |
| Format | `swift format -i -r .` then `swift format lint --strict --recursive .` | exit 0 |

Flag semantics were read from `Scripts/test.sh` at `8165d29` (unknown
arguments pass through to `xcodebuild`; `--only` implies app-only). Plan 037
edits that script; confirm with `Scripts/test.sh --help` before the first run.

Never run `xcodebuild test -scheme iMCP` directly, and never
`launchctl bootout` the always-on agent: the watchdog relaunches the installed
app and breaks the test host. `Scripts/test.sh` handles that.

## Scope

**In scope** (the only files you should modify):

- `CLI/StdioProxy.swift`
- `CLI/MCPService.swift`
- `CLI/CLIBootstrap.swift`
- `CLI/main.swift` (delete one line, step 1)
- `CLITests/CLIBootstrapTests.swift`
- `iMCP.xcodeproj/project.pbxproj`
- Step 5 only: `CLI/MessageFrameScanner.swift` (renamed to
  `CLI/StdinFrameScanner.swift`), `App/Shared/MessageFrameScanner.swift`
  (create), `App/Controllers/NWConnectionTransport.swift`,
  `CLITests/MessageFrameScannerTests.swift`, `AGENTS.md` (one line)

**Out of scope** (do NOT touch):

- Pairing-code handling and the body of the challenge-answering loop in
  `StdioProxy` — plan 043 owns it. You move that block verbatim in step 2;
  do not rewrite it.
- `CLI/MCPService.swift` joining the test target — it launches the real app
  and browses real Bonjour.
- `launchAppIfNotRunning`, `selectIMCPEndpoint`, `ClientKeyStore`,
  `ListenerEndpointFile`, `AuthPreamble` — unchanged.
- Any exit-code change. A terminated session keeps returning from `run()` as
  it does today (see Maintenance notes).
- `Scripts/`, CI workflow, other docs.

## Git workflow

- Branch: `advisor/044-cli-reliability-shared-framing`
- One commit per step. Conventional commits, e.g.
  `fix(cli): deliver a reply that arrives with the connection close`,
  `fix(cli): never replace a proxy that has consumed stdin`,
  `refactor: share one wire-frame scanner between the app and the CLI`.
- Do NOT push or open a PR unless the operator instructed it. `origin`
  (`cyberpapiii/iMCP`) is the only writable remote; `upstream`
  (`mattt/iMCP`) must never receive pushes or PRs.

## Steps

### Step 1: Compile `StdioProxy.swift` into the CLI test target

1. `StdioProxy.swift` uses two globals from `main.swift`. Remove one of the
   two dependencies: in `CLI/StdioProxy.swift:164` change the default
   `networkBufferSize: Int = defaultIOBufferSize` to
   `networkBufferSize: Int = 10 * 1024 * 1024`, and delete
   `let defaultIOBufferSize = 10 * 1024 * 1024` from `CLI/main.swift:12`.
   Confirm nothing else uses it:
   `grep -rn defaultIOBufferSize CLI CLITests` → no matches.

2. In `iMCP.xcodeproj/project.pbxproj` add these lines. Each goes next to the
   similar existing line named after it.

   PBXBuildFile section (next to the `ResumeGate.swift in Sources` line):

   ```
   		B04400010000000000000001 /* StdioProxy.swift in Sources */ = {isa = PBXBuildFile; fileRef = B04400020000000000000002 /* StdioProxy.swift */; };
   		B04400030000000000000003 /* ResumeGate.swift in Sources */ = {isa = PBXBuildFile; fileRef = B02900020000000000000002 /* ResumeGate.swift */; };
   ```

   PBXFileReference section (next to the `CLIBootstrap.swift` reference):

   ```
   		B04400020000000000000002 /* StdioProxy.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; name = StdioProxy.swift; path = ../CLI/StdioProxy.swift; sourceTree = "<group>"; };
   ```

   `CLITests` group children (`9784E568F0621136136A0EAC`), after
   `CLIBootstrap.swift`:

   ```
   				B04400020000000000000002 /* StdioProxy.swift */,
   ```

   Test Sources phase `B53F67B71CE8E2EB7B5CB823`, after
   `CLIBootstrap.swift in Sources`:

   ```
   				B04400010000000000000001 /* StdioProxy.swift in Sources */,
   				B04400030000000000000003 /* ResumeGate.swift in Sources */,
   ```

   First run `grep -c B0440 iMCP.xcodeproj/project.pbxproj` → `0` (the IDs
   are free). `ResumeGate.swift` already has a file reference and a group
   child; it only needs the build file and the Sources line.

3. `main.swift` cannot be in a test bundle, so the test target needs its own
   `log`. In `CLITests/CLIBootstrapTests.swift` add `import Logging` to the
   imports and, at file scope under the imports:

   ```swift
   /// `CLI/main.swift` owns the real logger and cannot be compiled into a test
   /// bundle. `StdioProxy` needs a main-actor `log` to exist.
   @MainActor var log = Logger(label: "imcp-serverTests")
   ```

**Verify**: `Scripts/test.sh --cli-only` → all pass, same test count as
before this step. Then the Build command → exit 0.

### Step 2: Deliver a reply that arrives together with the close (test first)

**2a. Extract the per-chunk work, keeping today's behaviour.** In
`CLI/StdioProxy.swift`, move the body of the `do` block in
`handleNetworkToStdout` (everything from `if isComplete {` at `:544` through
the end of the `for message in messages` loop at `:628`) into a new method
on the actor. Not `private`: the tests call it.

```swift
    /// Handles one read from the app. Internal rather than private so
    /// CLITests can drive a chunk without a socket.
    func handleNetworkChunk(_ data: Data, isComplete: Bool, stdout: FileDescriptor) async throws {
        if isComplete {
            await log.debug("Network connection complete")
            throw peerCloseError()
        }

        if data.isEmpty {
            return            // was `continue`
        }

        // ... lines 553-628 moved here unchanged ...
    }
```

The loop body becomes:

```swift
            do {
                let (data, isComplete) = try await receiveNetworkChunk(
                    from: connection,
                    bufferSize: bufferSize
                )
                try await handleNetworkChunk(data, isComplete: isComplete, stdout: stdout)
            } catch let error as NWError {
```

Leave the two `catch` clauses and the "No idle deadline" comment where they
are. Do not edit the moved lines (plan 043 may have changed the
challenge-answering part; move whatever is there).

**2b. Add the tests.** Append a second test class to
`CLITests/CLIBootstrapTests.swift` (same file, so no pbxproj entries are
needed; `CLITests/MessageFrameScannerTests.swift` is the exemplar for two
classes in one file). Add `import SystemPackage` to the file's imports.

```swift
final class StdioProxyTests: XCTestCase {
    private let reply = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n".utf8)

    /// Never started, so it opens no socket and reads no stdin.
    private func makeProxy() -> StdioProxy {
        StdioProxy(
            endpoint: .hostPort(host: "127.0.0.1", port: 9),
            parameters: CLIBootstrap.makeParameters()
        )
    }

    /// Feeds one chunk and returns what reached stdout, plus any error.
    private func deliver(
        _ chunk: Data,
        isComplete: Bool,
        to proxy: StdioProxy
    ) async -> (written: Data, error: (any Error)?) {
        let pipe = Pipe()
        var thrown: (any Error)?
        do {
            try await proxy.handleNetworkChunk(
                chunk,
                isComplete: isComplete,
                stdout: FileDescriptor(rawValue: pipe.fileHandleForWriting.fileDescriptor)
            )
        } catch {
            thrown = error
        }
        try? pipe.fileHandleForWriting.close()
        return (pipe.fileHandleForReading.readDataToEndOfFile(), thrown)
    }

    func testMessageIsWrittenToStdoutWithItsNewline() async {
        let result = await deliver(reply, isComplete: false, to: makeProxy())
        XCTAssertEqual(result.written, reply)
        XCTAssertNil(result.error)
    }

    func testPartialMessageIsHeldUntilItsNewline() async {
        let proxy = makeProxy()
        let first = await deliver(Data(reply.prefix(10)), isComplete: false, to: proxy)
        XCTAssertEqual(first.written, Data())
        let second = await deliver(Data(reply.dropFirst(10)), isComplete: false, to: proxy)
        XCTAssertEqual(second.written, reply)
    }

    /// The app's last reply and its close can arrive in one read. The reply
    /// used to be discarded.
    func testReplyDeliveredWithCloseIsWrittenBeforeTheProxyStops() async {
        let result = await deliver(reply, isComplete: true, to: makeProxy())
        XCTAssertEqual(result.written, reply)
        XCTAssertTrue(result.error is StdioProxyError)
    }

    func testCloseWithNoDataStopsTheProxy() async {
        let result = await deliver(Data(), isComplete: true, to: makeProxy())
        XCTAssertEqual(result.written, Data())
        XCTAssertTrue(result.error is StdioProxyError)
    }
}
```

**Verify (red)**:
`Scripts/test.sh --cli-only -only-testing:imcp-serverTests/StdioProxyTests`
→ exactly one failure, `testReplyDeliveredWithCloseIsWrittenBeforeTheProxyStops`
(`written` is empty). The other three pass. If that test passes here, STOP:
the extraction changed behaviour.

**2c. Fix.** In `handleNetworkChunk`, move the `if isComplete { ... throw }`
block from the top of the method to the very end (after the
`for message in messages` loop), and change the empty-data early return so it
does not skip the close:

```swift
        if !data.isEmpty {
            // ... the moved lines 553-628 ...
        }

        if isComplete {
            await log.debug("Network connection complete")
            throw peerCloseError()
        }
```

**Verify (green)**: same command → 4 tests pass. Then
`Scripts/test.sh --cli-only` → all pass.

### Step 3: Never replace a proxy that has consumed stdin

**3a. `CLI/StdioProxy.swift`.**

- Replace the `didCompleteInitialize` declaration and its doc comment
  (`:151-153`) with:

  ```swift
      /// Set once this proxy has taken any bytes off stdin. Those bytes cannot
      /// be replayed into a new connection, so from then on every failure ends
      /// the process instead of reconnecting.
      private(set) var hasConsumedStdin = false
  ```

- In `handleStdinToNetwork`, make `hasConsumedStdin = true` the first
  statement inside `for try await inputData in ...` (before the `guard`).
- Delete `peerCloseError()` (`:335-337`) and replace each of its seven call
  sites with `throw StdioProxyError.connectionClosed`.
- In the message loop delete the three lines that set
  `didCompleteInitialize` (`if !didCompleteInitialize, mcpMessageIsInitializeHandshakeReply(message) { ... }`).

**3b. `CLI/CLIBootstrap.swift`.** Delete `case connectFailed` from
`StdioProxyError`, and delete `stdioProxyErrorAfterPeerClose`,
`mcpMessageIsSuccessfulInitializeResult`, and
`mcpMessageIsInitializeHandshakeReply` (with the doc comment above the last
one). Add inside `enum CLIBootstrap`:

```swift
    // MARK: - Recovering from a failed connection

    enum ProxyFailureRecovery: Equatable {
        /// End the process. The client sees EOF and restarts the server.
        case terminate
        /// The app closed before the client sent anything: connect again.
        case reconnect
        /// The endpoint could not be reached: choose a discovery mode and retry.
        case rediscover
    }

    /// A proxy that has consumed stdin is never replaced. A new connection
    /// would be a session the client never initialized and the app never
    /// approved, and the client would wait forever on the old one.
    static func recovery(after error: any Error, hasConsumedStdin: Bool) -> ProxyFailureRecovery {
        if hasConsumedStdin { return .terminate }
        switch error as? StdioProxyError {
        case .connectionClosed: return .reconnect
        case .stdinClosed, .stdinFrameTooLarge: return .terminate
        case nil: return .rediscover
        }
    }
```

**3c. `CLI/MCPService.swift`.** Replace the body of the `while` loop in
`run()` (`:47-118`) so there is one `do`/`catch`. Lines marked "unchanged"
are the existing lines, moved without edits.

```swift
            var resolved: ResolvedEndpoint?
            var proxy: StdioProxy?
            do {
                let plan = try await resolveEndpoint(mode: discoveryMode)
                resolved = plan

                await log.info("Creating connection to endpoint...")

                let newProxy = StdioProxy(/* unchanged arguments */)
                proxy = newProxy
                // (unchanged SIGTERM/SIGINT comment)
                try await withGracefulShutdownHandler {
                    try await newProxy.start()
                } onGracefulShutdown: {
                    Task { await newProxy.stop() }
                }
                if Task.isShuttingDownGracefully { return }
            } catch {
                if Task.isShuttingDownGracefully { return }
                let hasConsumedStdin = await proxy?.hasConsumedStdin ?? false
                switch CLIBootstrap.recovery(after: error, hasConsumedStdin: hasConsumedStdin) {
                case .terminate:
                    if error as? StdioProxyError == .stdinClosed {
                        await log.info("Stdin closed by client, terminating...")
                    } else {
                        await log.critical("Connection ended mid-session (\(error)), terminating...")
                    }
                    return
                case .reconnect:
                    discoveryMode = .preferLoopback
                    await log.info("Connection closed before the client sent anything, will retry...")
                    try await Task.sleep(for: .seconds(1))
                case .rediscover:
                    // unchanged: old lines 101-117 (resolvedWasLoopback,
                    // discoveryMode, the two log lines, the 5 s sleep)
                }
            }
```

The inner `catch let error as StdioProxyError` and
`catch let error as NWError` blocks are gone.

**3d. Tests.** In `CLITests/CLIBootstrapTests.swift` delete
`testPeerCloseBeforeInitializeIsConnectFailed` and
`testInitializeHandshakeReplyIncludesErrors`, and add in their place
(modelled on the `appLaunchDecision` tests in the same file):

```swift
    func testAProxyThatConsumedStdinIsNeverReplaced() {
        let errors: [any Error] = [
            StdioProxyError.connectionClosed,
            StdioProxyError.stdinClosed,
            NWError.posix(.EPIPE),
            NWError.posix(.ECONNRESET),
            CancellationError(),
        ]
        for error in errors {
            XCTAssertEqual(
                CLIBootstrap.recovery(after: error, hasConsumedStdin: true),
                .terminate,
                "\(error)"
            )
        }
    }

    func testPeerCloseBeforeTheClientSpokeReconnects() {
        XCTAssertEqual(
            CLIBootstrap.recovery(after: StdioProxyError.connectionClosed, hasConsumedStdin: false),
            .reconnect
        )
    }

    func testStdinEndingIsTerminalEvenBeforeAnyBytes() {
        XCTAssertEqual(
            CLIBootstrap.recovery(after: StdioProxyError.stdinClosed, hasConsumedStdin: false),
            .terminate
        )
        XCTAssertEqual(
            CLIBootstrap.recovery(after: StdioProxyError.stdinFrameTooLarge, hasConsumedStdin: false),
            .terminate
        )
    }

    func testConnectFailureBeforeTheClientSpokeRediscovers() {
        XCTAssertEqual(
            CLIBootstrap.recovery(after: NWError.posix(.ECONNREFUSED), hasConsumedStdin: false),
            .rediscover
        )
    }
```

In `StdioProxyTests` (step 2), tighten the two close tests: replace
`XCTAssertTrue(result.error is StdioProxyError)` with
`XCTAssertEqual(result.error as? StdioProxyError, .connectionClosed)`.

**Verify**:
- `grep -rnE 'connectFailed|didCompleteInitialize|mcpMessageIs|stdioProxyErrorAfterPeerClose|peerCloseError' CLI CLITests` → no matches.
- `Scripts/test.sh --cli-only` → all pass.
- Build command → exit 0.

### Step 4: Watch the endpoint file while waiting on Bonjour

In `CLI/MCPService.swift`:

1. Change the signature to
   `private func discoverEndpointViaBonjour(watchingEndpointFile: Bool) async throws -> ResolvedEndpoint`.
2. Update the three callers in `resolveEndpoint(mode:)`:
   - invalid-port branch (`:176`): `return try await discoverEndpointViaBonjour(watchingEndpointFile: false)`
   - `.skip` branch (`:190`): `return try await discoverEndpointViaBonjour(watchingEndpointFile: true)`
   - `.bonjourOnly` (`:193`): `return try await discoverEndpointViaBonjour(watchingEndpointFile: false)`
3. In the browse-success path change
   `continuation.resume(returning: selectedEndpoint)` to
   `continuation.resume(returning: .bonjour(selectedEndpoint))`.
4. Replace the single 30 s sleep at the top of `timeoutTask` with a loop of
   the same total length that also checks the file. The timeout body after
   the loop is unchanged.

```swift
            let timeoutTask = Task {
                // The app this call may have just launched writes its endpoint
                // file as soon as its listener is up. Loopback needs no Local
                // Network permission, so take it the moment it appears instead
                // of waiting out Bonjour. 120 x 250 ms keeps the 30 s ceiling.
                for _ in 0 ..< 120 {
                    try await Task.sleep(for: .milliseconds(250))
                    guard watchingEndpointFile,
                        case .use(let handoff) = CLIBootstrap.loopbackResolution(
                            ListenerEndpointFile.inspect(
                                isTrustedProcess: ListenerEndpointFile.isSignedIMCPProcess
                            )
                        ),
                        let port = NWEndpoint.Port(rawValue: handoff.port)
                    else { continue }
                    if await resumeGate.shouldResume() {
                        browser.cancel()
                        await log.info(
                            "iMCP wrote its endpoint file (port \(handoff.port)); connecting via loopback"
                        )
                        continuation.resume(returning: .loopback(.hostPort(host: "127.0.0.1", port: port)))
                    }
                    return
                }

                if await resumeGate.shouldResume() {
                    // unchanged timeout body
                }
            }
```

`watchingEndpointFile` must stay `false` for `.bonjourOnly`: that mode means
the file's port was just tried and failed, and re-reading the same file would
loop on it forever (see the comment at `MCPService.swift:41-43`).

There is no unit test for this step: `MCPService` is deliberately outside the
test target. The decision it reuses (`CLIBootstrap.loopbackResolution`) is
already covered by `testLoopbackResolutionUsesUsableHandoffAndSkipsTheRest`.

**Verify**:
- Build command → exit 0.
- `grep -n 'seconds(30)' CLI/MCPService.swift` → no matches.
- `grep -c 'watchingEndpointFile: true' CLI/MCPService.swift` → `1`.
- `Scripts/test.sh --cli-only` → all pass.

**The plan is complete here if you stop.** Run the Format commands, commit,
and report. Step 5 is a separate, higher-risk refactor.

### Step 5: One frame scanner for the app and the CLI

Before starting, run `Scripts/test.sh` (both suites) → all pass. If not, STOP.

**5a. Move the scanner to shared code.**

1. `git mv CLI/MessageFrameScanner.swift CLI/StdinFrameScanner.swift`.
2. Create `App/Shared/MessageFrameScanner.swift` and move the
   `MessageFrameScanner` struct into it (with its doc comment and
   `import Foundation` / `import MCP`). `CLI/StdinFrameScanner.swift` keeps
   `MCPInitializeCompatibility` and `StdinFrameScanner`.
3. Move `static func isIgnorable(_:)` from `MessageFrameScanner` to
   `StdinFrameScanner` (the app has no use for it) and change the call in
   `StdinFrameScanner.consume` to `Self.isIgnorable(frame)`.
4. Change the shared scanner's API to ordered frames. Delete
   `pendingAuthChallenges` and `drainAuthChallenges()`. Target shape (the
   lines not shown inside `consume` are unchanged):

```swift
/// Incremental scanner for the wire format shared by the iMCP app and its
/// CLI. (keep the rest of the existing doc comment; drop the "Mirrors the
/// buffer scan in ..." sentence)
struct MessageFrameScanner {
    /// One thing the peer sent, in arrival order.
    enum Frame: Equatable {
        case message(Data)
        case authChallenge(AuthChallengeFrame)
        case authResponse(AuthResponseFrame)
    }

    private var buffer = Data()
    private var scannedByteCount = 0
    private(set) var isDisconnected = false

    /// Bytes received and not yet returned as a frame.
    var bufferedByteCount: Int { buffer.count }

    mutating func disconnect() { /* unchanged */ }

    /// Appends a received chunk and returns every complete frame it
    /// unlocked, in order. Messages come without their trailing newline;
    /// empty messages and heartbeats are dropped.
    mutating func consume(_ chunk: Data) -> [Frame] {
        guard !isDisconnected else { return [] }
        buffer.append(chunk)

        var frames: [Frame] = []
        while true {
            while let challenge = AuthChallengeFrame.from(data: buffer) {
                frames.append(.authChallenge(challenge))
                // unchanged: drop the frame, reset scannedByteCount
            }

            while let response = AuthResponseFrame.from(data: buffer) {
                frames.append(.authResponse(response))
                // unchanged: drop the frame, reset scannedByteCount
            }

            // unchanged: partial response break, rejected-frame disconnect
            // (return frames), partial challenge break, heartbeat strip,
            // partial heartbeat break, incremental newline scan

            if !messageData.isEmpty {
                frames.append(.message(Data(messageData)))
            }
            // unchanged
        }

        return frames
    }
}
```

5. pbxproj:
   - Repoint the existing reference `B0CAFE040000000000000004` from
     `path = ../CLI/MessageFrameScanner.swift` to
     `path = ../App/Shared/MessageFrameScanner.swift` (the test target keeps
     compiling it through the existing build file `B0CAFE03...`).
   - Compile it into the CLI target, like `ResumeGate.swift`. PBXBuildFile:

     ```
     		B04400040000000000000004 /* MessageFrameScanner.swift in Sources */ = {isa = PBXBuildFile; fileRef = B0CAFE040000000000000004 /* MessageFrameScanner.swift */; };
     ```
     and in the CLI Sources phase `F8F44EB22D5908D00075D79C`:
     ```
     				B04400040000000000000004 /* MessageFrameScanner.swift in Sources */,
     ```
   - Compile `StdinFrameScanner.swift` into the test target:

     ```
     		B04400050000000000000005 /* StdinFrameScanner.swift in Sources */ = {isa = PBXBuildFile; fileRef = B04400060000000000000006 /* StdinFrameScanner.swift */; };
     		B04400060000000000000006 /* StdinFrameScanner.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; name = StdinFrameScanner.swift; path = ../CLI/StdinFrameScanner.swift; sourceTree = "<group>"; };
     ```
     plus `B04400060000000000000006 /* StdinFrameScanner.swift */,` in the
     `CLITests` group children and
     `B04400050000000000000005 /* StdinFrameScanner.swift in Sources */,` in
     the test Sources phase `B53F67B71CE8E2EB7B5CB823`.

   The app target needs no entry (`App/` is a synchronized group).

**5b. CLI caller.** In `StdioProxy.handleNetworkChunk` replace

```swift
                let messages = frameScanner.consume(data)
                let challenges = frameScanner.drainAuthChallenges()
```

with

```swift
            var messages: [Data] = []
            var challenges: [AuthChallengeFrame] = []
            for frame in frameScanner.consume(data) {
                switch frame {
                case .message(let message): messages.append(message)
                case .authChallenge(let challenge): challenges.append(challenge)
                case .authResponse: break  // Only the CLI sends these.
                }
            }
```

Nothing else in the method changes.

**5c. CLI tests.** In `CLITests/MessageFrameScannerTests.swift`:

- Add at file scope:

  ```swift
  extension MessageFrameScanner {
      /// The messages a chunk unlocked, ignoring auth frames.
      fileprivate mutating func messages(in chunk: Data) -> [Data] {
          consume(chunk).compactMap { frame in
              if case .message(let data) = frame { return data }
              return nil
          }
      }
  }
  ```
- Inside `MessageFrameScannerTests` only (NOT `StdinFrameScannerTests`, whose
  `scanner` is a `StdinFrameScanner`), replace `scanner.consume(` with
  `scanner.messages(in: ` everywhere except the three tests below.
- Replace `MessageFrameScanner.isIgnorable` with
  `StdinFrameScanner.isIgnorable` (5 occurrences).
- Rewrite the three tests that used `drainAuthChallenges()`:

  ```swift
      func testReturnsAuthChallengeAsAFrameNotAMessage() {
          var scanner = MessageFrameScanner()
          let challenge = AuthChallengeFrame(connectionID: UUID())
          XCTAssertEqual(scanner.consume(challenge.encode()), [.authChallenge(challenge)])
          XCTAssertEqual(
              scanner.messages(in: message("{\"id\":1}") + newline),
              [message("{\"id\":1}")]
          )
      }

      func testReturnsAuthResponseAheadOfTheMessageBehindIt() throws {
          var scanner = MessageFrameScanner()
          let challenge = AuthChallengeFrame(connectionID: UUID())
          let response = try AuthResponseFrame.sign(
              challenge: challenge,
              privateKey: P256.Signing.PrivateKey()
          )
          let frames = scanner.consume(response.encode() + message("{\"id\":1}") + newline)
          XCTAssertEqual(frames.count, 2)
          guard case .authResponse = frames.first else {
              return XCTFail("expected the auth response first")
          }
          XCTAssertEqual(frames.last, .message(message("{\"id\":1}")))
      }

      func testBuffersAuthChallengeSplitAcrossChunks() {
          var scanner = MessageFrameScanner()
          let challenge = AuthChallengeFrame(connectionID: UUID())
          let frame = challenge.encode()
          XCTAssertEqual(scanner.consume(Data(frame.prefix(6))), [])
          XCTAssertEqual(
              scanner.consume(Data(frame.dropFirst(6)) + message("{\"id\":1}") + newline),
              [.authChallenge(challenge), .message(message("{\"id\":1}"))]
          )
      }
  ```
- Add two tests for what the app relies on:

  ```swift
      /// The app verifies a response before it yields any later message, so
      /// frames must come back in wire order.
      func testFramesKeepWireOrderAroundAnAuthResponse() throws {
          var scanner = MessageFrameScanner()
          let response = try AuthResponseFrame.sign(
              challenge: AuthChallengeFrame(connectionID: UUID()),
              privateKey: P256.Signing.PrivateKey()
          )
          let chunk =
              message("{\"id\":1}") + newline + response.encode() + message("{\"id\":2}") + newline
          let frames = scanner.consume(chunk)
          XCTAssertEqual(frames.count, 3)
          XCTAssertEqual(frames.first, .message(message("{\"id\":1}")))
          guard case .authResponse = frames[1] else {
              return XCTFail("expected the auth response second")
          }
          XCTAssertEqual(frames.last, .message(message("{\"id\":2}")))
      }

      func testBufferedByteCountTracksUnreturnedBytes() {
          var scanner = MessageFrameScanner()
          XCTAssertEqual(scanner.consume(message("{\"id\"")), [])
          XCTAssertEqual(scanner.bufferedByteCount, 5)
          _ = scanner.consume(message(":1}") + newline)
          XCTAssertEqual(scanner.bufferedByteCount, 0)
      }
  ```

**Verify (CLI half)**: Build command → exit 0. `Scripts/test.sh --cli-only`
→ all pass. Commit this as its own commit before touching the app.

**5d. App caller.** In `App/Controllers/NWConnectionTransport.swift`
`receiveLoop`, replace `var buffer = Data()` / `var scannedByteCount = 0`
(`:161-162`) with `var scanner = MessageFrameScanner()`, and replace
everything from `buffer.append(chunk)` (`:177`) through the end of the
`while true { ... }` scan (`:250`) with:

```swift
            if scanner.bufferedByteCount + chunk.count > 1_048_576 {
                logger.error("Receive buffer exceeded 1 MB, closing connection")
                messageContinuation.finish(throwing: MCPError.transportError(POSIXError(.ENOBUFS)))
                await disconnect()
                return
            }

            // Frames arrive in wire order, which is what keeps verification
            // ahead of the client's initialize when both land in one read.
            for frame in scanner.consume(chunk) {
                switch frame {
                case .authResponse(let response):
                    logger.trace("Processing auth response frame")
                    if let challenge = authChallenge, let handler = authResponseHandler {
                        // (keep the two existing comments: "Await inline..." and "One-shot...")
                        await handler(challenge, response)
                        authChallenge = nil
                    }
                case .message(let message):
                    messageContinuation.yield(message)
                case .authChallenge:
                    break  // Only the app sends challenges.
                }
            }

            if scanner.isDisconnected {
                await disconnect()
                return
            }
```

The `do { (chunk, isComplete) = try await receiveChunk() } catch { ... }`
above it and the `if isComplete { ... }` block below it are unchanged. The
overflow check is the same test as before (`buffer.count` after appending the
chunk), written without owning the buffer.

**5e. Docs.** In `AGENTS.md` (the `CLI/` bullet, ~line 72-74) change
`MessageFrameScanner.swift` to `StdinFrameScanner.swift`, and add
`MessageFrameScanner.swift` to the `App/Shared/` bullet's file list just
above it.

**Verify**:
- Build command → exit 0.
- `Scripts/test.sh` → both suites pass. In particular every test in
  `iMCPTests/NWConnectionTransportTests.swift` passes **unmodified**
  (`git diff --stat -- iMCPTests/` → empty).
- `grep -n 'scannedByteCount\|Heartbeat' App/Controllers/NWConnectionTransport.swift` → no matches.
- `grep -rn 'drainAuthChallenges\|pendingAuthChallenges' App CLI CLITests` → no matches.
- `test ! -e CLI/MessageFrameScanner.swift && echo gone` → `gone`.

### Step 6: Format

`swift format -i -r .` then `swift format lint --strict --recursive .` →
exit 0. `git status` shows only in-scope files. Commit.

## Test plan

- `CLITests/CLIBootstrapTests.swift`, new class `StdioProxyTests` (step 2):
  message written with newline; partial message held; **reply delivered with
  close is written** (the regression for defect 1); close with no data stops
  the proxy. Structural pattern: the second class in
  `CLITests/MessageFrameScannerTests.swift`.
- `CLITests/CLIBootstrapTests.swift`, four `recovery(after:hasConsumedStdin:)`
  tests (step 3) replacing the two deleted initialize-sniffing tests.
  Pattern: the `appLaunchDecision` tests in the same file.
- `CLITests/MessageFrameScannerTests.swift` (step 5): three rewritten auth
  tests, two new (wire order, buffered byte count).
- `iMCPTests/NWConnectionTransportTests.swift`: no edits; it is the safety
  net for step 5d (auth response stripping, rejected frames, overflow, peer
  close, heartbeats).
- Verification: `Scripts/test.sh` → all pass, including 8 new CLI tests after
  step 4 and 10 after step 5 (2 deleted in step 3).

## Done criteria

Steps 1–4 (required):

- [ ] Build command exits 0
- [ ] `Scripts/test.sh` exits 0; `StdioProxyTests` (4 tests) and the four
      `recovery` tests exist and pass
- [ ] `grep -rnE 'connectFailed|didCompleteInitialize|mcpMessageIs|stdioProxyErrorAfterPeerClose|peerCloseError|defaultIOBufferSize' CLI CLITests` returns no matches
- [ ] `grep -n 'seconds(30)' CLI/MCPService.swift` returns no matches
- [ ] `grep -c 'StdioProxy.swift in Sources' iMCP.xcodeproj/project.pbxproj` → `2`
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated (if present)

Step 5 (if done):

- [ ] `grep -rn 'drainAuthChallenges\|pendingAuthChallenges' App CLI CLITests` returns no matches
- [ ] `grep -n 'scannedByteCount' App/Controllers/NWConnectionTransport.swift` returns no matches
- [ ] `git diff --stat origin/main -- iMCPTests/` is empty
- [ ] `grep -c 'struct MessageFrameScanner' -r App CLI | grep -v ':0'` → exactly one line, `App/Shared/MessageFrameScanner.swift:1`

## STOP conditions

Stop and report back (do not improvise) if:

- The code at the locations in "Current state" does not match the excerpts in
  shape (after allowing for plans 037 and 043).
- Step 1: the test target fails with `no such module 'SystemPackage'`, or with
  missing symbols other than `log` and `defaultIOBufferSize` (for example
  `serviceType` or `parameters`). That means `StdioProxy.swift` grew a new
  dependency on `main.swift`; do not add `main.swift` or `MCPService.swift`
  to the test target.
- Step 2: the red run does not fail exactly
  `testReplyDeliveredWithCloseIsWrittenBeforeTheProxyStops`.
- Step 3: plan 043 has changed `StdioProxyError`, `MCPService.run()`'s catch
  structure, or added another consumer of `.connectFailed`, so the target
  shape no longer applies cleanly.
- Step 5: any test in `iMCPTests/NWConnectionTransportTests.swift` fails after
  5d. Do not edit that test file to make it pass. Revert the step-5 commits
  (`git revert`), leave steps 1–4 in place, and report which test failed.
- Step 5: the build reports a duplicate file name or a duplicate symbol
  `MessageFrameScanner` — the pbxproj edit or the rename is wrong; fix once,
  then stop if it persists.
- Any verification fails twice after a reasonable fix attempt.
- A fix appears to require touching an out-of-scope file.

## Maintenance notes

- **Do not install.** The normal local-dev finish is
  `Scripts/install-local.sh run`; do not run it unless the operator asks.
- **Behaviour changes a reviewer should confirm are intended:**
  - Peer close after the client's first stdin bytes now ends the process
    (previously: reconnect unless an initialize reply had been seen). Peer
    close before any stdin still reconnects after 1 s.
  - Any error after stdin was consumed ends the process, including ones that
    used to fall into the 5 s rediscover loop (for example a failed send).
  - `NWError` `ENOTCONN`/`ECONNRESET` with **no** stdin consumed now goes
    through the 5 s rediscover path instead of exiting. Mid-session it still
    exits.
  - The app now drops a complete auth *challenge* frame sent by a client
    instead of letting its bytes corrupt the next message (step 5).
- **Exit code is unchanged on purpose.** A terminated session returns from
  `run()` and the process exits as it does today. Throwing instead would
  surface as a top-level fatal error (see the comment in `CLI/main.swift`
  above the `ServiceGroup`). Clients detect the EOF on stdout. If a non-zero
  exit is wanted later, it needs an explicit `exit(1)`, not a throw.
- **Known residual window**: bytes the stdin dispatch source has read but the
  proxy loop has not yet iterated are lost if the connection dies in that
  instant, and `hasConsumedStdin` is still false. Closing it means owning
  stdin in `MCPService` across proxies; deferred as not worth the code.
- **Not covered by tests**: `handleStdinToNetwork` (reads the process's real
  stdin) and all of `MCPService` (launches the app, real Bonjour). Step 4 is
  verified by build and inspection only. An operator can confirm it by
  quitting iMCP, starting a client, and checking the CLI log for
  "iMCP wrote its endpoint file".
- **The `log` shim** in `CLITests/CLIBootstrapTests.swift` exists only because
  `main.swift` cannot join a test bundle. If the real logger ever moves out of
  `main.swift`, delete the shim.
- **Plan 043 interaction**: 043 changes when the pairing code is sent. If it
  adds state to `StdioProxy` that is keyed on the endpoint kind, the
  `.loopback` result produced by step 4's file watch must be treated the same
  as the `.use` branch in `resolveEndpoint` (it passed the same pid/signature
  inspection).
- **Future framing changes** (for example the deferred auth-frame version
  bump) now happen in one place, `App/Shared/MessageFrameScanner.swift`, and
  are exercised by both `CLITests/MessageFrameScannerTests.swift` and
  `iMCPTests/NWConnectionTransportTests.swift`.
