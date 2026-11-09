# Plan 014: Extract a pure Claude Desktop config-merge function and characterize it with tests

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- App/Integrations/ClaudeDesktop.swift`
> If `App/Integrations/ClaudeDesktop.swift` changed since this plan was written,
> compare the "Current state" excerpt against the live code before proceeding; on
> a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: MED
- **Depends on**: none (this plan establishes the App-side test target that other
  plans defer their tests to)
- **Category**: tests / tech-debt
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

`ClaudeDesktop.updateConfig` merges iMCP's entry into the user's existing Claude
Desktop `claude_desktop_config.json`. It has already caused a **data-loss bug**
(#150: the save panel overwrote the user's config). The merge logic — the part
that must never drop a user's other MCP servers — is currently interleaved with
`NSAlert`/`NSSavePanel` UI calls in one method, which makes it impossible to unit
test and easy to break again. There are two near-duplicate merge branches, so the
correct behavior isn't even expressed in one place. This plan extracts the merge
into a **pure, UI-free function** and adds characterization tests around it —
including a regression test for the #150 overwrite. This also establishes the
**App-side unit-test target** that plans 001, 002, 006, 007, 008, 010, 011, and
012 defer their automated tests to.

## Current state

- `App/Integrations/ClaudeDesktop.swift` (~305 lines). `updateConfig`
  (`~195-290`) reads the existing config, merges in the iMCP server entry, and
  writes it back — interleaved with `NSAlert` prompts and an `NSSavePanel`. Two
  near-duplicate merge branches exist at `~205-210` and `~273-278`.

Representative shape (read the real code before extracting):

```swift
// ~195-290, abbreviated
func updateConfig() {
    // ...read existing JSON (or default) ...
    if var servers = existing["mcpServers"] as? [String: Any] {
        servers["iMCP"] = imcpEntry            // branch A (~205-210)
        existing["mcpServers"] = servers
    } else {
        existing["mcpServers"] = ["iMCP": imcpEntry]   // branch B (~273-278)
    }
    // ...NSSavePanel / NSAlert / write to disk...
}
```

- **Test infrastructure**: the only existing test target is `imcp-serverTests`
  (CLI tests, `CLITests/ServiceGroupConfigurationTests.swift`), which tests the
  CLI, not the App. There is **no App-side test target** yet. The CLI test file
  is the structural pattern to copy (XCTest, `@testable import`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| List schemes/targets | `xcodebuild -list -project iMCP.xcodeproj` | current targets |
| Format (write) | `swift format -i -r .` | exit 0 |
| Format lint | `swift format lint --strict --recursive .` | exit 0, no output |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | `** BUILD SUCCEEDED **` |
| Run App tests | `xcodebuild test -scheme iMCP -destination "platform=macOS"` | `** TEST SUCCEEDED **` |

**Xcode project note**: creating a new unit-test target and adding files requires
editing `iMCP.xcodeproj/project.pbxproj`. This is fiddly and easy to corrupt. If
you cannot do it reliably, see STOP conditions — extracting the pure function is
still valuable on its own and can ship without the target.

## Scope

**In scope**:
- `App/Integrations/ClaudeDesktop.swift` (extract the pure merge function; call
  it from `updateConfig`)
- A new App-side unit-test target (e.g. `iMCPTests`) and a test file for the merge
- `iMCP.xcodeproj/project.pbxproj` (register the target/files)

**Out of scope**:
- The UI flow itself (`NSAlert`/`NSSavePanel`) — leave the user interaction
  exactly as-is; only lift the *merge computation* out of it.
- Behavior change to what gets written — the extracted function must reproduce
  current behavior (minus the #150 bug, which the tests will pin down).

## Steps

### Step 1: Extract a pure merge function

Add a static, UI-free function that takes the current config data (or a parsed
dictionary) plus the iMCP entry and returns the merged result — no disk I/O, no
`NSAlert`, no `NSSavePanel`. Suggested signature:

```swift
// Pure: no I/O, no UI. Deterministic and unit-testable.
static func mergedConfig(existing: Data?, imcpEntry: [String: Any]) throws -> Data
```

Collapse the two duplicate merge branches (`~205-210`, `~273-278`) into this one
function so "add-or-replace the iMCP server while preserving all other servers"
is expressed once. Then change `updateConfig` to call it and keep doing the
UI/disk work around it.

**Verify**: build succeeds; `updateConfig` no longer contains inline merge logic;
`grep -n "mcpServers" App/Integrations/ClaudeDesktop.swift` shows the merge only
inside the new function.

### Step 2: Create the App-side unit-test target

Create an `iMCPTests` unit-test target testing the `iMCP` app target
(`@testable import iMCP` or the app module name). Model the file structure on
`CLITests/ServiceGroupConfigurationTests.swift` (XCTest). Register the target in
the project and ensure `xcodebuild test -scheme iMCP` discovers it.

**Verify**: `xcodebuild test -scheme iMCP -destination "platform=macOS"` runs and
reports the new (initially empty or single-test) suite.

### Step 3: Write characterization + regression tests for the merge

Add tests covering at least:
1. **Preserves other servers** (the #150 regression): given an existing config
   with a user server `"other"`, `mergedConfig` returns a config that still
   contains `"other"` AND adds/updates `"iMCP"`.
2. **Empty/nil existing**: `existing == nil` produces a valid config with just
   `iMCP`.
3. **Existing has no `mcpServers` key**: the key is created without dropping
   other top-level keys.
4. **Idempotence**: merging twice yields the same result as merging once.
5. **Malformed existing JSON**: define and assert the intended behavior (throw vs.
   fall back) — pick the safe one (prefer *throw and leave the user's file
   untouched* over *overwrite*), and document it.

**Verify**: `xcodebuild test -scheme iMCP -destination "platform=macOS"` →
`** TEST SUCCEEDED **` with these tests present and passing.

### Step 4: Format, build, test

Run `swift format -i -r .`, build, and run the App tests.

**Verify**: build `** BUILD SUCCEEDED **`; App tests `** TEST SUCCEEDED **`;
`swift format lint --strict --recursive .` exits 0.

## Test plan

The tests *are* the deliverable here (see Step 3). The merge function is pure, so
these are fast, deterministic, and need no filesystem. Ensure the #150 "preserves
other servers" case is present — that's the regression that justifies the plan.

## Done criteria

ALL must hold:

- [ ] A pure, UI-free `mergedConfig(...)`-style function exists; the two duplicate
      merge branches are collapsed into it
- [ ] `updateConfig` calls it and retains the existing UI/disk flow
- [ ] An App-side unit-test target exists and is discovered by `xcodebuild test -scheme iMCP`
- [ ] Tests cover: preserves other servers (#150), nil existing, missing
      `mcpServers` key, idempotence, malformed input
- [ ] `xcodebuild test -scheme iMCP -destination "platform=macOS"` prints `** TEST SUCCEEDED **`
- [ ] `xcodebuild ... build` prints `** BUILD SUCCEEDED **`
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `plans/README.md` status row updated
- [ ] Report notes that the App test target is now available for plans 001/002/006/007/008/010/011/012

## STOP conditions

Stop and report if:

- You cannot create the unit-test target without risking `project.pbxproj`
  corruption. **Fallback**: still extract the pure `mergedConfig` function
  (Step 1) and ship that improvement; report that the test target needs to be
  created in Xcode by a human, and include the test cases as a ready-to-add file.
- The current merge behavior is itself buggy in a way the tests would encode as
  "correct" — if you find `updateConfig` *currently* drops other servers in some
  path, STOP and report it as a live bug rather than characterizing the bug as
  intended behavior.
- The code doesn't match the "Current state" excerpt (drift).

## Maintenance notes

- Once this target exists, wire it into CI (plan 004) as a second test scheme so
  the App tests run on every push, and update `CLAUDE.md` (plan 005) with the App
  test command.
- The other deferred-test plans (001, 002, 006, 007, 008, 010, 011, 012) can add
  their tests here once this lands.
- Reviewer should confirm the extracted function has zero UIKit/AppKit references
  (that's what makes it testable) and that the #150 case genuinely fails against
  the old inline logic.
