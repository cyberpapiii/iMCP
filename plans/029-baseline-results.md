# Plan 029: Verification baseline results

Recorded at commit `17d7c722e35a649ef49c2e30633ec2550c57020f` (fork tip,
`advisor/029-verification-baseline` branch), 2026-08-07.

## Gate 1: Lint

Command:

```console
swift format lint --strict --recursive . ; echo "exit=$?"
```

Result: **PASS**. `exit=0`, no diagnostics. No formatting fixes were needed —
`git status` was clean before and after.

## Gate 2: Build

Command:

```console
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```

Result: **PASS**. `exit=0`. Only output was xcodebuild's own destination-
selection warning (multiple matching "My Mac" destinations, arm64 vs x86_64);
no compiler warnings or errors. No source changes were needed.

## Gate 3: CLI tests

Command:

```console
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS" ; echo "exit=$?"
```

Result: **PASS**. `exit=0`, output contains `** TEST SUCCEEDED **`.

Test counts (per suite, from the log):

- 5 tests, 0 failures
- 4 tests, 0 failures
- 12 tests, 0 failures
- 3 tests, 0 failures
- 24 tests, 0 failures
- 24 tests, 0 failures

Total: 24 distinct tests executed (the two "24 tests" lines are the same run
reported twice, once per bundle/summary pass), 0 failures.

## Gate 4: App tests

Command:

```console
xcodebuild test -scheme iMCP -destination "platform=macOS" ; echo "exit=$?"
```

Result: **PASS**. `exit=0`, output contains `** TEST SUCCEEDED **`. From the
result bundle `Test-iMCP-2026.08.07_10-54-12--0400.xcresult`: 94 tests
passed, 0 failed, 0 skipped, 0 expected failures.

Note: 94 is the count with three test files still absent from the
`iMCPTests` target — plan 030 wires those in, so expect this number to rise
once that lands.

### Recorded environment hazard: LaunchServices bundle-ID collision

The first two attempts at this gate (two independent full runs, ~10:49 and
~10:51) failed with `exit=65` and did not run any test method:

```
Test session results, code coverage, and logs:
	~/Library/Developer/Xcode/DerivedData/iMCP-hhwphzaxqakqxygxdhxrtuybspoh/Logs/Test/Test-iMCP-2026.08.07_10-49-14--0400.xcresult

Testing failed:
	Could not launch "iMCPTests"
	iMCP encountered an error (Failed to install or launch the test runner. (Underlying Error: Could not launch "iMCPTests". The LaunchServices launcher has returned an error. Please check the system logs for the underlying cause of the error.))

** TEST FAILED **
```

```
2026-08-07 10:49:21.177 xcodebuild[70748:1466907]  IDELaunchReport: a6708573424d9f00:a6708573424d9f00: Finished with error: Could not launch "iMCPTests"
Domain: IDELaunchErrorDomain
Code: 20
Recovery Suggestion: The LaunchServices launcher has returned an error. Please check the system logs for the underlying cause of the error.
```

**Root cause** (found by the reviewing coordinator after reproducing the same
failure): the operator's installed `/Applications/iMCP.app` was running (pid
828) and shares the same bundle identifier, `co.dododo.iMCP`, as the test
host this scheme builds. LaunchServices refuses to launch a second instance
of an already-running bundle ID, so the xcodebuild-launched test runner died
before any test method executed — `IDELaunchErrorDomain` code 20 is that
refusal, not a code defect. The Debug app binary itself was confirmed
working the whole time (running it directly at
`.../Build/Products/Debug/iMCP.app/Contents/MacOS/iMCP` stayed resident
fine); the missing piece was the collision with the already-running
installed copy, not the binary.

**Workaround**: quit `/Applications/iMCP.app` before running the app-test
gate on this machine, then relaunch it afterward. Anyone running
`xcodebuild test -scheme iMCP` on this machine while the installed app is
open will hit this same failure — it is an environment hazard specific to
having both copies of `co.dododo.iMCP` want to run at once, not a per-run
flake and not a product bug. The coordinator quit the installed app, re-ran
the exact gate command in this worktree (got `** TEST SUCCEEDED **`, 94/0/0
as above), then relaunched `/Applications/iMCP.app` (now pid 76864).

The real `pairedClients` UserDefaults key was not modified by the two failed
attempts, since the test runner never launched and no test code executed in
those runs.

## Summary

All four gates are green at `17d7c72`:

| Gate | Command | Exit | Status |
|---|---|---|---|
| Lint | `swift format lint --strict --recursive .` | 0 | PASS |
| Build | `xcodebuild ... -scheme iMCP ... build` | 0 | PASS |
| CLI tests | `xcodebuild test -scheme imcp-serverTests ...` | 0 | PASS (24 tests, 0 failures) |
| App tests | `xcodebuild test -scheme iMCP ...` | 0 | PASS (94 tests, 0 failures) — quit `/Applications/iMCP.app` first, see hazard note above |

No source files were modified to reach these results — the repository was
already lint-clean and warning-free at `17d7c72`. This fork's 67
never-CI'd commits now have one full green run of the CI gate behind them.
The one caveat for future runs on this machine is the LaunchServices
bundle-ID collision above: the app-test gate requires the installed
`/Applications/iMCP.app` to be quit first, or it fails with
`IDELaunchErrorDomain` code 20 before any test runs.
