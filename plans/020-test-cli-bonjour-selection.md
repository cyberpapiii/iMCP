# Plan 020: Test CLI Bonjour endpoint selection (regression guard for d53b9a1)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 5caccce..HEAD -- CLI/main.swift CLITests/ App/Controllers/NetworkDiscoveryManager.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `5caccce`, 2026-07-06
- **Executed at**: commit `815767f`, branch `advisor/020-test-cli-bonjour-selection`
- **Result**: DONE

## Why this matters

Commit `d53b9a1` fixed a **fail-always** Bonjour mismatch: the CLI's
`selectIMCPEndpoint` filters browse results for the substring `"iMCP"`, but the
app listener previously advertised under the Bonjour default (device hostname).
Every CLI connection failed with `"No unambiguous iMCP service found"` until
the app was changed to advertise with `name: "iMCP"` in
`NetworkDiscoveryManager.makeListener`. Plan 017 added fail-closed selection
logic but **explicitly deferred tests** because `NWBrowser.Result` is awkward
to construct. Without tests, this class of bug can ship again silently — it
survived CI and was only caught during a live Plug install.

## Current state

CLI selection — `CLI/main.swift:469-483`:

```swift
private func selectIMCPEndpoint(from results: Set<NWBrowser.Result>) throws -> NWEndpoint {
    let candidates = results.filter {
        String(describing: $0.endpoint).contains("iMCP")
    }

    guard !candidates.isEmpty else {
        throw MCPError.internalError("No unambiguous iMCP service found")
    }

    guard candidates.count == 1, let selected = candidates.first else {
        throw MCPError.internalError("Multiple iMCP services found")
    }

    return selected.endpoint
}
```

App advertisement (fixed in `d53b9a1`) — `App/Controllers/NetworkDiscoveryManager.swift:27-34`:

```swift
// Advertise under an explicit name: the CLI's selectIMCPEndpoint
// filters candidates on "iMCP", and the Bonjour default (the device
// hostname) would never match.
listener.service = NWListener.Service(
    name: "iMCP",
    type: serviceType,
    domain: serviceDomain
)
```

Existing CLI tests: `CLITests/MessageFrameScannerTests.swift`,
`CLITests/ServiceGroupConfigurationTests.swift` — neither covers endpoint
selection.

Test pattern to follow: `CLITests/MessageFrameScannerTests.swift` — plain
`XCTestCase`, no network I/O, tests a pure function.

Repo commands:

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| CLI tests | `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` | exit 0 |
| Format lint | `swift format lint --strict --recursive .` | exit 0 |

## Scope

**In scope**:

- `CLI/BonjourEndpointSelection.swift` (create — pure selection helper)
- `CLI/main.swift` (call helper instead of inline `selectIMCPEndpoint`)
- `CLITests/BonjourEndpointSelectionTests.swift` (create)
- `iMCP.xcodeproj/project.pbxproj` (add new source/test files to targets if needed)

**Out of scope**:

- Changing selection rules (keep `"iMCP"` substring + exactly-one candidate)
- App-side listener tests (optional comment cross-reference only)
- CLI network polling refactor
- Live Bonjour integration tests

## Git workflow

- Branch: `advisor/020-test-cli-bonjour-selection`
- Commit style: `test: cover CLI Bonjour endpoint selection and hostname regression`
- Do NOT push or open a PR unless the operator asks.

## Steps

### Step 1: Extract testable selection helper

Create `CLI/BonjourEndpointSelection.swift` with:

```swift
enum BonjourEndpointSelectionError: Error, Equatable {
    case noMatch
    case ambiguous(count: Int)
}

/// Returns true when the endpoint description would be selected as an iMCP candidate.
func isIMCPEndpointCandidate(_ endpointDescription: String) -> Bool {
    endpointDescription.contains("iMCP")
}

/// Select the single matching candidate description, mirroring selectIMCPEndpoint logic.
func selectUniqueIMCPEndpointDescription(from descriptions: [String]) throws -> String {
    let candidates = descriptions.filter(isIMCPEndpointCandidate)
    guard !candidates.isEmpty else { throw BonjourEndpointSelectionError.noMatch }
    guard candidates.count == 1, let selected = candidates.first else {
        throw BonjourEndpointSelectionError.ambiguous(count: candidates.count)
    }
    return selected
}
```

Update `CLI/main.swift`:

- Replace the body of `selectIMCPEndpoint(from:)` to map `results` to
  `String(describing: $0.endpoint)` descriptions, call
  `selectUniqueIMCPEndpointDescription(from:)`, map errors to the existing
  `MCPError.internalError("No unambiguous iMCP service found")` /
  `"Multiple iMCP services found"` strings, and return the matching result's
  `.endpoint`.

Keep `selectIMCPEndpoint` private in `main.swift` or move it beside the helper
in the new file — either way, **one** implementation of the filter/count rules.

**Verify**: `grep -n 'contains("iMCP")' CLI/main.swift CLI/BonjourEndpointSelection.swift` → logic appears only in `BonjourEndpointSelection.swift`.

### Step 2: Add regression tests

Create `CLITests/BonjourEndpointSelectionTests.swift` with cases:

| Test | Input descriptions | Expected |
|------|-------------------|----------|
| `testSelectsSingleIMCPEndpoint` | `["iMCP._mcp._tcp.local."]` | returns that string |
| `testRejectsHostnameOnlyAdvertisement` | `["Example-MacBook-Pro._mcp._tcp.local."]` | throws `.noMatch` — **d53b9a1 regression** |
| `testRejectsEmptySet` | `[]` | throws `.noMatch` |
| `testRejectsMultipleIMCPCandidates` | two strings both containing `iMCP` | throws `.ambiguous(count: 2)` |
| `testSelectsIMCPAmongMixedCandidates` | hostname + one iMCP description | returns iMCP description |

Add a test comment linking the hostname case to commit `d53b9a1`.

Model structure after `CLITests/MessageFrameScannerTests.swift`.

Add files to `imcp-server` and `imcp-serverTests` targets in the Xcode project.

**Verify**:

```console
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS" -only-testing:imcp-serverTests/BonjourEndpointSelectionTests
```

→ exit 0, 5 tests pass.

### Step 3: Document cross-side invariant

Add a one-line comment in `App/Controllers/NetworkDiscoveryManager.swift` near
`listener.service = NWListener.Service(name: "iMCP", ...)` pointing to
`CLI/BonjourEndpointSelection.swift` — **must stay in sync** with
`isIMCPEndpointCandidate`. This edit is a comment only.

**Verify**: `git diff App/Controllers/NetworkDiscoveryManager.swift` → comment-only change.

### Step 4: Format and full CLI test suite

```console
swift format -i -r .
swift format lint --strict --recursive .
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"
```

All exit 0.

## Test plan

- Five unit tests on pure strings (no `NWBrowser.Result` construction).
- Full `imcp-serverTests` scheme green.
- Regression test explicitly encodes pre-`d53b9a1` failure mode (hostname-only).

## Done criteria

- [x] Selection filter logic lives in `CLI/BonjourEndpointSelection.swift`
- [x] `testRejectsHostnameOnlyAdvertisement` exists and passes
- [x] `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` → exit 0
- [x] `swift format lint --strict --recursive .` → exit 0
- [x] NetworkDiscoveryManager comment references CLI helper
- [x] `plans/README.md` status row for 020 updated to DONE

## STOP conditions

Stop and report if:

- `selectIMCPEndpoint` logic already extracted and fully tested.
- App listener no longer uses `name: "iMCP"` (drift from `d53b9a1` fix).
- Extracting the helper requires a new Swift package target the plan did not
  anticipate — propose minimal target wiring before proceeding.

## Maintenance notes

- Any change to Bonjour service name or CLI filter rules must update **both**
  `NetworkDiscoveryManager.makeListener` and `BonjourEndpointSelection.swift`
  plus these tests.
- Future crypto/pairing work (plan 015 phases 020+) may replace substring
  matching — delete or rewrite these tests when that lands, don't leave a false
  sense of security.
