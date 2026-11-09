# Plan 009: Read service-enablement flags on the MainActor, not off-actor

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- App/Controllers/ServerController.swift`
> If `App/Controllers/ServerController.swift` changed since this plan was written,
> compare the "Current state" excerpts against the live code before proceeding;
> on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none (but touches the same file as plan 013 — see ordering note)
- **Category**: bug / concurrency
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

The MCP `ListTools` and `CallTool` handlers run inside the `ServerNetworkManager`
actor but reach out to read `serviceBindings[serviceId]?.wrappedValue` — and
those bindings are `@MainActor`-isolated `@AppStorage` projected values. Reading
a main-actor `@AppStorage` binding's `wrappedValue` from a non-main actor is a
cross-actor access to main-actor state: it is a data race under Swift's
concurrency model, can return a torn/stale enablement flag, and is exactly the
class of bug that shipped as the #166 and #150 regressions in this file. The
correct pattern is to snapshot the enablement flags on the MainActor once, then
pass the plain `Bool` values into the actor. After this plan, no service-
enablement flag is read off the MainActor.

## Current state

- `App/Controllers/ServerController.swift` — the network/MCP core. Relevant
  structure:
  - `@MainActor final class ServerController` owns the `@AppStorage`-backed
    service enablement state and exposes `serviceBindings` (a dictionary of
    `Binding<Bool>` projected values), roughly `ServerController.swift:154-415`.
  - `actor ServerNetworkManager` holds the MCP `Server` and registers the
    handlers, roughly `ServerController.swift:625-1031`.

The off-actor reads (the defect), `ServerController.swift:879` and `:929`:

```swift
// inside the ListTools handler (actor context), ~line 879
let isEnabled = await self.serviceBindings[serviceId]?.wrappedValue ?? false

// inside the CallTool handler (actor context), ~line 929
guard await self.serviceBindings[serviceId]?.wrappedValue ?? false else { ... }
```

`serviceBindings` is populated from the `@MainActor` controller; each value is a
SwiftUI `Binding<Bool>` whose `wrappedValue` getter touches `@AppStorage`
(`UserDefaults`) under main-actor isolation. The `await` here hops actors but the
binding's storage is not `Sendable`/actor-isolated in a way that makes this safe.

Read `ServerController.swift:154-260` to see exactly how `serviceBindings` /
`serviceConfig` / the enablement `@AppStorage` properties are declared before
choosing the snapshot shape.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format (write) | `swift format -i -r .` | exit 0 |
| Format lint (CI gate) | `swift format lint --strict --recursive .` | exit 0, no output |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | `** BUILD SUCCEEDED **` |

Warnings are errors; a Sendable/isolation warning WILL fail the build, which is
useful here — a clean build is strong evidence the race is gone.

## Scope

**In scope**:
- `App/Controllers/ServerController.swift`

**Out of scope**:
- The service implementations in `App/Services/` — unchanged.
- Plan 013 (splitting `ServerController` into multiple files) — do NOT start that
  here. If plan 013 lands first, the handler code may live in a new file; adapt
  the excerpt locations accordingly but keep this change minimal.

## Ordering note

Plans 009 and 013 both edit `ServerController.swift`. Recommended order: **009
before 013** (fix the race in place, then let the refactor carry the corrected
code). If 013 has already landed, find the `ListTools`/`CallTool` handlers in
their new home and apply the same change.

## Git workflow

- Branch: `advisor/009-snapshot-service-enablement`
- Single commit; short imperative message (e.g. "Snapshot service enablement on
  MainActor before entering network actor").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a MainActor snapshot accessor on ServerController

On `@MainActor final class ServerController`, add a method that returns a plain
`Sendable` snapshot of enablement — e.g.:

```swift
func enabledServiceIDsSnapshot() -> Set<String> {
    Set(serviceBindings.compactMap { id, binding in binding.wrappedValue ? id : nil })
}
```

Return a `Set<String>` (or `[String: Bool]`) — both are `Sendable`. This runs on
the MainActor, so reading `wrappedValue` is safe here.

**Verify**: build succeeds; the accessor is annotated (implicitly, via the
`@MainActor` class) main-actor.

### Step 2: Pass the snapshot into the network actor instead of reading bindings

Change `ServerNetworkManager` so it no longer holds/reads `serviceBindings`
directly for the enablement check. Two acceptable shapes — pick one and note it:

- **Push**: whenever enablement changes (and at startup), the MainActor calls an
  actor method like `func updateEnabledServices(_ ids: Set<String>)` that stores
  the snapshot inside the actor; the handlers read the actor-local `Set`.
- **Pull-at-call**: the handlers `await MainActor.run { controller.enabledServiceIDsSnapshot() }`
  (or call the `@MainActor` accessor) at the top of `ListTools`/`CallTool` and
  use the returned value.

Push is lower-latency and avoids a MainActor hop per call; pull is simpler and
always fresh. Prefer **push** if the enablement-change site is easy to find
(search for where `serviceBindings`/`@AppStorage` toggles are observed);
otherwise pull is acceptable.

Replace both off-actor reads (`:879`, `:929`) with the snapshot value.

**Verify**: `grep -n "serviceBindings\[.*\]?.wrappedValue" App/Controllers/ServerController.swift`
→ no matches inside actor-isolated handler code. `grep -n "await self.serviceBindings" App/Controllers/ServerController.swift`
→ no matches.

### Step 3: Format and build

Run `swift format -i -r .` then build.

**Verify**: `** BUILD SUCCEEDED **` with no Sendable/isolation warnings;
`swift format lint --strict --recursive .` exits 0.

## Test plan

No App-side unit-test target exists yet (plan 014 establishes one). This change
is primarily compiler-verified (the isolation error goes away because the access
is now correct). Verification:
- Clean build with no concurrency warnings.
- Manual (record results): if you can run the app, toggle a service off in the
  menu bar and confirm `ListTools` no longer lists that service's tools and
  `CallTool` on one of its tools is rejected; toggle back on and confirm they
  reappear. This exercises the snapshot's freshness.

## Done criteria

ALL must hold:

- [ ] No actor-isolated handler reads `serviceBindings[...].wrappedValue` off the MainActor
- [ ] Enablement is snapshotted on the MainActor and passed in as a `Sendable` value
- [ ] `xcodebuild ... build` prints `** BUILD SUCCEEDED **` with no concurrency warnings
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] Only `App/Controllers/ServerController.swift` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- The reads aren't at `:879`/`:929` or the surrounding structure differs from the
  "Current state" excerpt (drift, or plan 013 already refactored — adapt per the
  Ordering note and note it).
- Choosing "push" requires wiring an observation of `@AppStorage` changes that
  doesn't already exist and would balloon the change — fall back to "pull" and
  note it.
- Removing the direct binding read breaks another consumer of `serviceBindings`
  you didn't expect — report what else reads it.

## Maintenance notes

- After this, `serviceBindings` should be consumed only on the MainActor (UI +
  snapshot). A reviewer should grep for any other off-actor `wrappedValue` read.
- If plan 013 later moves the handlers, keep the snapshot-based enablement check
  intact — do not "simplify" it back to a direct binding read.
