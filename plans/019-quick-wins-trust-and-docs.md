# Plan 019: Quick wins — sanitize tool errors and README services

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 5caccce..HEAD -- App/Controllers/ServerNetworkManager.swift App/Services/Photos.swift README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `5caccce`, 2026-07-06
- **Executed at**: commit `a70d79c`, branch `advisor/019-quick-wins-trust-and-docs`
- **Result**: DONE — Steps 1, 3–5 landed. **Step 2 (Photos read-only) invalid** — see below.

## Why this matters

Two small changes tighten the trust boundary and fix onboarding docs. `CallTool`
returns full Swift error descriptions (including filesystem paths and SQLite
detail) to any approved MCP client. The README Capabilities table lists 10
services while `ServiceRegistry` registers 16 — six privacy-sensitive
capabilities are invisible to evaluators.

**Invalid audit finding (second pass #9):** The plan originally called for
switching Photos to `.readOnly` authorization. `PHAccessLevel` has only
`.addOnly` (write-only, cannot read) and `.readWrite`. There is no read-only
level; `.readWrite` is already the minimum access that permits reading the
library. Do not attempt this step again.

## Current state

Relevant files:

- `App/Controllers/ServerNetworkManager.swift` — `CallTool` handler; error path
  at lines 444–451. After `a70d79c`, errors go through
  `App/Controllers/ToolErrorResponse.swift` (`sanitizedToolErrorMessage`).
- `README.md` — Capabilities table at lines 14–78 lists Calendar through
  Weather (10 rows). Missing: Browser History, Call History, Notes,
  Notifications, Photos, Screen Time (`App/Controllers/ServiceRegistry.swift:77-167`).

Current error echo, `App/Controllers/ServerNetworkManager.swift:444-451`:

```swift
} catch {
    serverLog.error(
        "Error executing tool \(params.name): \(error.localizedDescription)"
    )
    return CallTool.Result(
        content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
        isError: true
    )
}
```

Logging convention: use `serverLog.error(...)` for full detail server-side;
user-facing MCP text should be stable and path-free. Match existing handler
messages like the unapproved-connection case at `:362-367`.

Repo commands (verified in `CLAUDE.md` and `.github/workflows/ci.yml`):

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format lint | `swift format lint --strict --recursive .` | exit 0 |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| App tests | `xcodebuild test -scheme iMCP -destination "platform=macOS"` | exit 0 |

## Scope

**In scope** (as executed):

- `App/Controllers/ServerNetworkManager.swift`
- `App/Controllers/ToolErrorResponse.swift` (create)
- `iMCPTests/ToolErrorSanitizationTests.swift` (create)
- `README.md`

**Out of scope / invalid**:

- ~~Photos `.readOnly` authorization~~ — **invalid** (`PHAccessLevel` has no
  `.readOnly`; see Status). Do not modify `App/Services/Photos.swift` for this.
- `CallTool` performance / cache routing (backlog)
- CLI polling (backlog)
- Approval TTL UX (deferred)

## Git workflow

- Branch: `advisor/019-quick-wins-trust-and-docs`
- Commit style: match repo — e.g. `fix: sanitize CallTool errors returned to MCP clients`
- Do NOT push or open a PR unless the operator asks.

## Steps

### Step 1: Sanitize `CallTool` error responses

In `App/Controllers/ServerNetworkManager.swift`, replace the catch block at
`:444-451` so that:

1. Full error detail is logged with `serverLog.error` (keep
   `error.localizedDescription` in the log line).
2. The MCP client receives a stable, generic message — e.g.
   `"Tool execution failed. See iMCP logs for details."` — with **no**
   interpolation of `error`, `localizedDescription`, paths, or NSError domains.

Do not change successful result paths or the "tool not found" message at
`:456-461` (tool names are not sensitive).

Add a small `@testable import iMCP` helper if needed — e.g. a package-visible
function `sanitizedToolErrorMessage(for:)` — **only if** testing the string
without standing up a full MCP server is otherwise impractical. Prefer testing
through a package-internal helper in a new file `App/Controllers/ToolErrorResponse.swift`
if that keeps `ServerNetworkManager` readable.

**Verify**: `grep -n 'Error: \\\\(error)' App/Controllers/ServerNetworkManager.swift` → no matches.

### ~~Step 2: Switch Photos to read-only authorization~~ — INVALID, SKIP

**Do not execute.** Second-audit finding #9 was wrong: `PHAccessLevel` offers
only `.addOnly` and `.readWrite`. `.readWrite` is already least privilege for
read access. Executor at `a70d79c` correctly skipped this step.

### Step 3: Add README rows for six missing services

Extend the Capabilities `<table>` in `README.md` with one row each for:

| Service | Suggested description (adapt from tool intent) |
|---------|------------------------------------------------|
| Browser History | Search recent browsing history from Safari, Chrome, and Arc with filters for browser, date range, and URL/title search. |
| Call History | Fetch recent phone and FaceTime calls with direction, date range, and contact/address filters. |
| Notes | List Notes folders and search notes by title/content within optional folder scope. |
| Notifications | Search notification history by title, body, and date range (requires database access grant). |
| Photos | Search the photo library by date, media type, and album with optional place-name enrichment. |
| Screen Time | Query Screen Time / device usage insights from the Knowledge database. |

Use the same table structure as existing rows (icon column may be empty like
Capture/Shortcuts). Do **not** add a hard-coded tool count — keep the existing
qualitative wording at `README.md:195-198`.

**Verify**: `grep -c '<td><strong>' README.md` → **16** (or 15 if Weather row
is build-gated in your checkout — count must match `ServiceRegistry` service
count minus Weather when `WEATHERKIT_AVAILABLE` is off).

### Step 4: Tests

**Tool error sanitization** — create `iMCPTests/ToolErrorSanitizationTests.swift`:

- Test the helper (or a package-internal function) with an `NSError` whose
  `userInfo` contains a fake path like `/Users/test/secret/chat.db`.
- Assert the sanitized client message does **not** contain `chat.db`, `/Users/`,
  or the NSError domain string.

Model after `iMCPTests/ToolResultTests.swift` structure. (Executed: two tests in
`ToolErrorSanitizationTests.swift`.)

Add the new test file to the `iMCP` test target in `iMCP.xcodeproj` if Xcode
does not pick it up automatically.

**Verify**: `xcodebuild test -scheme iMCP -destination "platform=macOS" -only-testing:iMCPTests/ToolErrorSanitizationTests` → exit 0.

**Note:** Quit the installed iMCP app before running tests if the runner
collides on bundle ID with the installed build.

### Step 5: Format and full verification

**Verify**:

```console
swift format -i -r .
swift format lint --strict --recursive .
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build
xcodebuild test -scheme iMCP -destination "platform=macOS"
```

All exit 0.

## Test plan

- `ToolErrorSanitizationTests` — path/domain stripped from client message.
- Existing suite must remain green.

## Done criteria

- [x] `grep 'Error: \\(error)' App/Controllers/ServerNetworkManager.swift` → no matches
- [x] ~~Photos `.readOnly`~~ — N/A (step invalid)
- [x] README lists all services present in `ServiceRegistry` (16)
- [x] `ToolErrorSanitizationTests` pass
- [x] `swift format lint --strict --recursive .` → exit 0
- [x] `xcodebuild test -scheme iMCP -destination "platform=macOS"` → exit 0
- [x] `plans/README.md` status row for 019 updated to DONE

## STOP conditions

Stop and report if:

- `CallTool` catch block structure differs materially from the excerpt (e.g.
  errors already sanitized).
- README table already lists all 16 services.
- Sanitization requires changing MCP SDK types outside `ServerNetworkManager`.

## Maintenance notes

- If new services add `CallTool` handlers elsewhere, keep `sanitizedToolErrorMessage`
  in `ToolErrorResponse.swift` as the single place for client-visible tool errors.
- Photos authorization: keep `.readWrite` — it is not over-privileged for read
  tools; there is no `.readOnly` in `PHAccessLevel`.
- Reviewers should confirm README descriptions mention database/file-picker
  grants where applicable (Messages-adjacent services).
