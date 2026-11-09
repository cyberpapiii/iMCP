# Plan 022: Route CallTool through cached tool-definition map

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 815767f..HEAD -- App/Controllers/ServerNetworkManager.swift App/Models/Service.swift iMCPTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: perf
- **Executed at**: commit `83fd87f`, branch `advisor/022-calltool-cache-dispatch`
- **Result**: DONE

## Why this matters

Plan 012 added `cachedToolDefinitions()` so `ListTools` avoids rebuilding every
service's `@ToolBuilder` block on each request. `CallTool` still loops all
enabled services and calls `service.call(tool:with:)`, which scans each service's
`tools` array (`App/Models/Service.swift:18-20`). Under frequent MCP traffic
this is O(enabled services × tools per service) on every invocation — the hot
path the cache was meant to optimize.

## Current state

**ListTools** uses the cache — `App/Controllers/ServerNetworkManager.swift:341-345`:

```swift
for definition in try await self.cachedToolDefinitions()
where enabledServiceIDs.contains(definition.serviceID) {
    tools.append(definition.mcpTool)
}
```

**CallTool** scans services — `App/Controllers/ServerNetworkManager.swift:390-403`:

```swift
let enabledServiceIDs = await self.enabledServiceIDs
for service in await self.services {
    let serviceId = String(describing: type(of: service))
    if enabledServiceIDs.contains(serviceId) {
        do {
            guard let result = try await service.call(
                tool: params.name,
                with: params.arguments ?? [:]
            ) else {
                continue
            }
            // ... build CallTool.Result ...
```

**Cache structure** — `App/Controllers/ServerNetworkManager.swift:27-31`, `:472-497`:

```swift
private struct ToolDefinition {
    let serviceID: String
    let localTool: Tool
    let mcpTool: MCP.Tool
}
```

Tool names are globally unique across `App/Services/*.swift` (verified: no
duplicate `name:` values). `enabledServiceIDs` is still checked at call time so
disabled services cannot execute tools.

Error handling for tool failures uses `sanitizedToolErrorMessage(for:)` from
`App/Controllers/ToolErrorResponse.swift` (plan 019).

Repo commands:

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| App tests | `xcodebuild test -scheme iMCP -destination "platform=macOS"` | exit 0 |
| Format lint | `swift format lint --strict --recursive .` | exit 0 |

## Scope

**In scope**:

- `App/Controllers/ServerNetworkManager.swift`
- `iMCPTests/CallToolDispatchTests.swift` (create)

**Out of scope**:

- Invalidating/rebuilding cache on service toggle (ListTools already filters by
  `enabledServiceIDs`; same pattern for CallTool)
- Changing tool result encoding (plan 011 DONE)
- CLI polling (plan 023)

## Git workflow

- Branch: `advisor/022-calltool-cache-dispatch`
- Commit style: `perf: dispatch CallTool via cached tool map`
- Do NOT push or open a PR unless the operator asks.

## Steps

### Step 1: Add name-indexed lookup beside the cache

In `ServerNetworkManager`, extend caching:

1. Keep `toolDefinitionCache: [ToolDefinition]?`.
2. Add `toolDefinitionByName: [String: ToolDefinition]?` (or compute from the
   array in one helper — prefer a single `rebuildToolDefinitionCache()` that
   sets both).
3. Add `private func toolDefinition(named: String) throws -> ToolDefinition?`
   that builds the cache on first use (same as today) and returns the entry for
   `named`.

When building definitions, if two tools share a name (should not happen),
log `serverLog.error` and keep the first — add a DEBUG assertion or unit test
that all names are unique.

**Verify**: build succeeds.

### Step 2: Rewrite CallTool dispatch

Replace the `for service in services` loop with:

1. Look up `toolDefinition(named: params.name)`.
2. If nil → fall through to existing "Tool not found or service not enabled"
   response at `:462-467`.
3. If `!enabledServiceIDs.contains(definition.serviceID)` → same not-found
   response (do not leak which service owns a disabled tool).
4. Invoke `try await definition.localTool.callAsFunction(params.arguments ?? [:])`
   directly — **not** `service.call`.
5. Keep the existing `switch result` branches and `sanitizedToolErrorMessage`
   catch path unchanged.

**Verify**: `grep -n 'service.call' App/Controllers/ServerNetworkManager.swift` → no matches inside `CallTool` handler.

### Step 3: Tests

Create `iMCPTests/CallToolDispatchTests.swift`:

Because `ServerNetworkManager` is an actor tied to Network.framework, test the
lookup helper with package-internal access:

- Extract `func resolveToolDefinition(named:from definitions: [ToolDefinition]) -> ToolDefinition?`
  as `internal` in `ServerNetworkManager.swift` or a small
  `App/Controllers/ToolDefinitionCache.swift` if cleaner.

Tests:

1. `testUniqueToolNamesAcrossRegistry` — build definitions from
   `ServiceRegistry.services` (or iterate `cachedToolDefinitions` logic in test)
   and assert Set of names.count == definitions.count.
2. `testResolveReturnsNilForUnknownName` — empty/single-definition fixtures.
3. `testResolveReturnsDefinitionForKnownName` — use one real tool name e.g.
   `"utilities_beep"`.

Model after `iMCPTests/ToolErrorSanitizationTests.swift`.

Add file to `iMCP` test target if needed.

**Verify**: `xcodebuild test -scheme iMCP -destination "platform=macOS" -only-testing:iMCPTests/CallToolDispatchTests` → exit 0.

### Step 4: Format and full verification

```console
swift format -i -r .
swift format lint --strict --recursive .
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build
xcodebuild test -scheme iMCP -destination "platform=macOS"
```

All exit 0. Quit the installed iMCP app before app tests if bundle ID collides.

## Test plan

- Name-uniqueness guard across all services.
- Lookup helper happy/unknown paths.
- Full app test suite green.

## Done criteria

- [x] `CallTool` uses cached `localTool` dispatch, not `service.call` loop
- [x] Disabled service IDs still block execution
- [x] `CallToolDispatchTests` pass
- [x] `swift format lint --strict --recursive .` → exit 0 (on commit `83fd87f`)
- [x] `xcodebuild test -scheme iMCP -destination "platform=macOS"` → exit 0
- [x] `plans/README.md` status row for 022 updated to DONE

## STOP conditions

Stop and report if:

- Duplicate tool names exist and cannot be resolved without product decision.
- `localTool.callAsFunction` behavior differs from `service.call` for any tool
  (investigate before proceeding).
- Cache structure changed materially from excerpts.

## Maintenance notes

- New services/tools must keep globally unique tool names — the uniqueness test
  guards this.
- If tool definitions become dynamic (runtime registration), revisit cache
  invalidation; today services are static singletons.
