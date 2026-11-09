# Plan 017: Make CLI Bonjour endpoint selection fail closed

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- CLI/main.swift`
> If `CLI/main.swift` changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `b84f266`, 2026-07-03

## Why this matters

`imcp-server` is the stdio executable that MCP clients launch. It discovers the
menu-bar app over Bonjour and proxies all JSON-RPC traffic to the selected local
endpoint. Today, if no discovered `_mcp._tcp` endpoint description contains
`iMCP`, the CLI falls back to `results.first!`. That means an unrelated or
malicious local `_mcp._tcp` advertiser can receive the user's MCP traffic when
the real app is absent, slow to advertise, or named unexpectedly. This plan
does not solve full endpoint authentication - plan 015 covers that - but it
removes the arbitrary first-result fallback and makes discovery fail closed.

## Current state

- `CLI/main.swift` - stdio-to-Network.framework proxy and Bonjour discovery.

Discovery configuration, `CLI/main.swift:17-31`:

```swift
let serviceType = "_mcp._tcp"
let parameters = NWParameters.tcp
parameters.acceptLocalOnly = true
parameters.includePeerToPeer = false
...
let browser = NWBrowser(
    for: .bonjour(type: serviceType, domain: nil),
    using: parameters
)
```

Current endpoint selection, `CLI/main.swift:537-565`:

```swift
if !results.isEmpty {
    // First, try to find a service with "iMCP" in the endpoint description
    let imcpServices = results.filter {
        String(describing: $0.endpoint).contains("iMCP")
    }

    let selectedService: NWBrowser.Result

    if !imcpServices.isEmpty {
        // Prefer services with iMCP in the description
        selectedService = imcpServices.first!
        await log.info(
            "Selected iMCP service: \(selectedService.endpoint)"
        )
    } else {
        // Fall back to the first available service
        selectedService = results.first!
        await log.info(
            "No specific iMCP service found, using: \(selectedService.endpoint)"
        )
    }

    if await connectionState.checkAndSetResumed() {
        timeoutTask.cancel()
        browser.cancel()
        await log.info("Selected endpoint: \(selectedService.endpoint)")
        continuation.resume(returning: selectedService.endpoint)
    }
}
```

The current code also chooses the first matching `iMCP` description when more
than one exists. That is less dangerous than `results.first!`, but still
ambiguous.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format (write) | `swift format -i -r .` | exit 0 |
| Format lint | `swift format lint --strict --recursive .` | exit 0, no output |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| CLI tests | `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` | `** TEST SUCCEEDED **` |

## Scope

**In scope**:
- `CLI/main.swift`
- Optional: `CLITests/ServiceGroupConfigurationTests.swift` only if a pure
  selection helper can be tested by adding cases to the existing test file.

**Out of scope**:
- Adding TLS, pairing, cryptographic identity, or protocol changes.
- Changing the app-side Bonjour advertiser in `App/Controllers/ServerController.swift`.
- Editing the MCP Swift SDK or service implementations.
- Adding new test files or editing `iMCP.xcodeproj/project.pbxproj` just for
  this plan. If the helper cannot be tested in the existing test file, defer
  unit coverage and report why.

## Git workflow

- Branch: `advisor/017-require-unambiguous-imcp-bonjour`
- Single commit; short imperative message, e.g. "Fail closed on ambiguous iMCP discovery".
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Extract explicit iMCP candidate selection

Replace the inline `imcpServices` / `selectedService` block with a helper inside
`MCPService.run()` or a private function near the discovery code. The helper
should:

- Accept the current `Set<NWBrowser.Result>`.
- Filter candidates to endpoints that look like iMCP.
- Return a selected endpoint only when there is exactly one candidate.
- Throw a clear `MCPError.internalError(...)` when there are zero or more than
  one iMCP-looking candidates.

Use the current `String(describing: endpoint).contains("iMCP")` as the minimum
candidate predicate for this plan. If you can safely pattern-match
`NWEndpoint.service(name:type:domain:interface:)` and check a more precise
service name/type, do that, but do not expand this plan into a full pairing or
TLS implementation.

**Verify**:
`grep -n "results.first!\\|No specific iMCP service found" CLI/main.swift`
-> no matches.

### Step 2: Resume discovery with an error on zero or ambiguous candidates

In `browseResultsChangedHandler`, when there are results but the helper cannot
select exactly one iMCP candidate, log a warning and do not proxy to a fallback
endpoint. Two acceptable behaviors:

- Keep waiting until timeout, so the existing 30-second timeout reports service
  discovery failure, OR
- Resume immediately with a clear `MCPError.internalError("No unambiguous iMCP service found")`
  for zero candidates and `"Multiple iMCP services found"` for ambiguity.

Prefer immediate failure when there are non-iMCP results but no iMCP result; it
surfaces misconfiguration faster. Keep waiting when `results` is empty.

**Verify**:
read the code and confirm `continuation.resume(returning:)` is called only with
an endpoint selected by the helper's exactly-one rule.

### Step 3: Add narrow unit coverage if practical

The current `imcp-serverTests` suite covers service lifecycle, not Bonjour
selection. If you made the candidate-selection helper pure enough to test
without constructing real `NWBrowser.Result` values, add tests in
`CLITests/ServiceGroupConfigurationTests.swift` covering:

- zero candidates -> nil/error
- one iMCP candidate -> selected
- multiple iMCP candidates -> nil/error
- non-iMCP candidates only -> nil/error

If `NWBrowser.Result` is not constructible in tests, testing would require real
Bonjour services, or a new test file/project edit would be needed, skip test
creation and record that in your report.

**Verify**:
`xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"`
-> `** TEST SUCCEEDED **`.

### Step 4: Format, build, and test

Run:

```console
swift format -i -r .
swift format lint --strict --recursive .
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"
```

**Verify**: format lint exits 0; build exits 0; tests print `** TEST SUCCEEDED **`.

## Test plan

- Prefer unit tests for the selection helper if it can be made pure.
- Otherwise, this plan is verified by source inspection plus existing CLI tests:
  the dangerous `results.first!` fallback is gone, and the CLI cannot return an
  endpoint unless it matched iMCP unambiguously.
- Manual smoke, if available: run the app and launch `imcp-server`; it should
  still connect when exactly one iMCP app is advertising.

## Done criteria

ALL must hold:

- [ ] `results.first!` is not used for Bonjour endpoint selection
- [ ] The CLI never proxies to a non-iMCP `_mcp._tcp` endpoint as fallback
- [ ] Multiple iMCP-looking candidates are treated as ambiguous, not silently
      first-picked
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `xcodebuild ... build` exits 0
- [ ] `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` prints `** TEST SUCCEEDED **`
- [ ] Only `CLI/main.swift`, optional existing `CLITests/ServiceGroupConfigurationTests.swift`,
      and `plans/README.md` are modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- There is no stable way to recognize the app's Bonjour service beyond
  arbitrary endpoint description text and removing fallback would break normal
  launched-app discovery on this machine.
- A robust fix appears to require app-side protocol changes, pairing, TLS, or
  SDK changes. That is plan 015/future security work, not this small fail-closed
  patch.
- Tests require real local network services and become flaky.

## Maintenance notes

- This plan is an immediate fail-closed mitigation. It does not authenticate the
  endpoint; any local process could still advertise a service named like iMCP.
  Plan 015 must remain open for durable endpoint identity.
- Reviewer should confirm UX for "app not running" is understandable: the CLI
  should fail clearly instead of hanging forever or routing to another service.
