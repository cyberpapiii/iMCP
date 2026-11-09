# Plan 012: Cache tool definitions instead of rebuilding them per ListTools call

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- App/Controllers/ServerController.swift App/Models`
> If these changed since this plan was written, compare the "Current state"
> excerpt against the live code before proceeding; on a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW
- **Depends on**: 009, 013
- **Category**: perf
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

The `ListTools` handler rebuilds the full tool list — every service's `Tool`
definitions, each with its JSON Schema — on every single call, then filters by
enablement. MCP clients call `ListTools` on connect and again whenever they
refresh, and iMCP has ~29 tools across 10 services. The tool *definitions*
(name, description, input schema) are static for a given build; only the
*enablement filter* changes at runtime. Rebuilding the static half each time is
wasted allocation and schema construction on a hot, latency-visible path (the
client blocks on it during connection). After this plan, definitions are built
once and cached, and each `ListTools` only applies the enablement filter.

## Current state

- `App/Controllers/ServerController.swift` — the `ListTools` handler is around
  `ServerController.swift:860-900`. It iterates the service registry, collects
  each service's tools, and reads enablement per service (the enablement read is
  the subject of plan 009). The per-call cost is the *construction* of the tool
  array, not just the filter.

Read the actual handler body and the `ServiceRegistry` / `serviceConfig`
declarations (`ServerController.swift:50-152`) to see how services and their
tools are enumerated. Confirm whether `Tool` definitions are cheap value types
or whether building them constructs `JSONSchema` objects each time (the latter is
the expensive part worth caching).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format (write) | `swift format -i -r .` | exit 0 |
| Format lint (CI gate) | `swift format lint --strict --recursive .` | exit 0, no output |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |

## Scope

**In scope**:
- `App/Controllers/ServerController.swift` (the `ListTools` handler and a cache
  field on the actor that owns it)

**Out of scope**:
- The `Tool`/`Service` model types — don't change their shape here (plan 011
  touches `Tool`; keep these independent).
- The enablement snapshot mechanism — that's plan 009; this plan assumes
  enablement is a cheap `Set<String>`/`[String:Bool]` lookup and caches only the
  static definitions.

## Ordering note

This plan shares `ServerController.swift` with plans 009 and 013. Required order
for this plan set: **009 → 013 → 012** (fix the race, do the structural split,
then add the cache in the settled structure). The cache must sit behind the
corrected enablement check from 009, not the old off-actor read.

## Steps

### Step 1: Confirm the cost is in definition-building, not the filter

Read the `ListTools` handler. Establish whether each call constructs new `Tool`/
`JSONSchema` instances (cacheable win) or merely maps over already-built static
values (little to gain). If the definitions are already built once at startup and
`ListTools` only filters, there is little to do — STOP and report that the
optimization isn't warranted rather than adding a cache for its own sake.

**Verify**: you can state in your report where the allocation happens.

### Step 2: Build the definition cache once

Add a lazily-populated, actor-isolated cache of the full tool-definition list
(all services, unfiltered) on the actor that serves `ListTools`. Populate it once
(lazily on first `ListTools`, or at server start). Because tool definitions are
static for the process lifetime, the cache never needs invalidation.

Keep the cache keyed so the enablement filter can still be applied per call —
e.g. cache `[(serviceID: String, tools: [Tool])]` and filter by the enabled set.

**Verify**: read the code — the tool/schema construction runs once, not per call.

### Step 3: ListTools = cached definitions + enablement filter

Rewrite the handler to: read the cached definitions, apply the enablement
snapshot (from plan 009), and return. No per-call construction of `Tool` or
`JSONSchema`.

**Verify**: `ListTools` body no longer constructs tool definitions inline; it
reads the cache and filters.

### Step 4: Format and build

Run `swift format -i -r .` then build.

**Verify**: the build command exits 0; `swift format lint --strict --recursive .` exits 0.

## Test plan

No App-side unit-test target exists yet (plan 014 establishes one). Verification:
- Build clean.
- Manual (record results): if you can run the app, connect a client and confirm
  the tool list is identical to before (same tools for the same enabled
  services), and toggling a service still adds/removes its tools (proves the
  filter is still applied per call while definitions are cached).
- Optional: if you can time it, note `ListTools` latency before/after under a
  client that lists repeatedly.

## Done criteria

ALL must hold:

- [ ] Tool definitions (name/description/schema) are constructed once and cached,
      not rebuilt per `ListTools`
- [ ] `ListTools` still applies the enablement filter per call (toggling a
      service changes the returned list)
- [ ] The returned tool list is unchanged from before for the same enabled set
- [ ] `xcodebuild ... build` exits 0
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] Only `App/Controllers/ServerController.swift` and `plans/README.md` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- Step 1 shows definitions are already built once — report that this plan isn't
  worth doing and stop (no cache-for-its-own-sake).
- Tool definitions turn out to depend on runtime state (per-connection, per-user)
  such that they can't be safely cached process-wide — report what the dependency
  is.
- The handler structure differs materially from the "Current state" description
  (drift, or plan 013 moved it — adapt and note).

## Maintenance notes

- The cache assumes tool definitions are static for the process lifetime. If a
  future feature makes tools dynamic (e.g. user-defined tools, per-connection
  tool sets), this cache needs an invalidation story — call that out in review.
- Reviewer should confirm no thread/actor other than the owner mutates the cache.
