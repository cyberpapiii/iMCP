# Plan 010: `messages_fetch` stops over-fetching from the Messages database

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- App/Services/Messages.swift`
> If `App/Services/Messages.swift` changed since this plan was written, compare
> the "Current state" excerpt against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: MED
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

`messages_fetch` is the single most privacy-sensitive read tool in the app (it
decodes the iMessage database). Its limit handling forces a floor of 1024 rows:
`limit: max(limit ?? defaultLimit, 1024)`. Because `defaultLimit` is 30, a
default call still pulls **at least 1024 messages** out of the database, then —
when a `query` is present — filters them down in memory and returns far fewer.
The effect is that every default fetch decodes and materializes ~34× more of the
user's private message history than it returns, wasting CPU/memory and widening
the blast radius of any bug that logs or leaks the intermediate array. After this
plan, the fetch pulls roughly what it returns, and search is bounded.

## Current state

- `App/Services/Messages.swift` — the Messages service; `messages_fetch` is the
  only tool (`readOnlyHint`).

`defaultLimit` (`Messages.swift:10`):

```swift
private let defaultLimit = 30
```

The over-fetch (`Messages.swift:130-152`, key lines):

```swift
let messages = try await database.messages(
    in: chat,
    startDate: startDate,
    endDate: endDate,
    limit: max(limit ?? defaultLimit, 1024)   // <-- floor of 1024 regardless of requested limit
)

var filtered = messages
if case .string(let searchText) = arguments["query"], !searchText.isEmpty {
    filtered = filtered.filter {                // in-memory search over the 1024+ rows
        $0.text?.localizedCaseInsensitiveContains(searchText) == true
    }
}
return filtered.prefix(limit ?? defaultLimit).map { ... }
```

The date range (`startDate`/`endDate`) is correctly normalized above this block
(uses the `normalizedStartDate`/`normalizedEndDate` helpers), so it is not part
of this bug.

Read the `database.messages(in:startDate:endDate:limit:)` signature (it comes
from the `Madrid` package) to confirm whether it supports a search/text
predicate. If it does, that's the better fix (push search into the query); if it
does not, the fix is to raise the fetch limit only enough to satisfy in-memory
search, not to a blanket 1024.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format (write) | `swift format -i -r .` | exit 0 |
| Format lint (CI gate) | `swift format lint --strict --recursive .` | exit 0, no output |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | `** BUILD SUCCEEDED **` |
| Inspect Madrid API | `grep -rn "func messages" $(find . -type d -name "*Madrid*" 2>/dev/null)` | the query signature |

## Scope

**In scope**:
- `App/Services/Messages.swift`

**Out of scope**:
- The `Madrid` package source — do not vendor-edit a dependency. If pushing
  search into the query requires a Madrid API that doesn't exist, STOP and report
  (see STOP conditions); do not fork Madrid in this plan.
- The date-normalization logic — correct, leave it.

## Git workflow

- Branch: `advisor/010-fix-messages-fetch-limit`
- Single commit; short imperative message.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Determine whether Madrid can filter by text in-query

Inspect the `database.messages(...)` API. If it accepts a search/text parameter,
plan to pass `query` down and remove the in-memory filter. If it does not,
proceed with Step 2's bounded-overfetch approach.

**Verify**: you can state, in your report, whether Madrid supports in-query text
search.

### Step 2: Replace the 1024 floor with a bounded limit

- If Madrid supports in-query search: pass the `query` into
  `database.messages(...)`, request `limit ?? defaultLimit`, and drop the
  in-memory `.filter`. No 1024 floor.
- If Madrid does NOT support in-query search: replace `max(limit ?? defaultLimit,
  1024)` with a **modest** search headroom multiplier that scales with the
  requested limit rather than a flat 1024 — e.g. when a `query` is present, fetch
  `min((limit ?? defaultLimit) * K, hardCap)` (choose a small `K`, e.g. 5–10, and
  a `hardCap` such as 500, and document both); when no `query` is present, fetch
  exactly `limit ?? defaultLimit`. Keep the final `.prefix(limit ?? defaultLimit)`.

Whichever branch, a **no-query default call must not fetch 1024 rows** — it should
fetch ~`defaultLimit`.

**Verify**: `grep -n "1024" App/Services/Messages.swift` → no matches. Read the
code: a default (no-query) call requests `defaultLimit`, not a large floor.

### Step 3: Format and build

Run `swift format -i -r .` then build.

**Verify**: `** BUILD SUCCEEDED **`; `swift format lint --strict --recursive .` exits 0.

## Test plan

No App-side unit-test target exists yet (plan 014 establishes one). Because this
needs the Messages DB, unit testing requires a fixture DB that is out of scope
here. Verification:
- Build clean.
- Manual (record results): if you can run the app with Messages access, call
  `messages_fetch` with no `query` and confirm it returns ~`defaultLimit`
  messages promptly; call with a `query` and confirm search still returns
  matches. Note the approximate row counts fetched vs returned if observable.

## Done criteria

ALL must hold:

- [ ] The `max(..., 1024)` floor is gone; `grep -n "1024" App/Services/Messages.swift` is empty
- [ ] A no-query default fetch requests approximately `defaultLimit` rows, not a large floor
- [ ] If a headroom multiplier is used for search, it scales with the requested
      limit and has a documented hard cap
- [ ] `xcodebuild ... build` prints `** BUILD SUCCEEDED **`
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] Only `App/Services/Messages.swift` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- The code doesn't match the "Current state" excerpt (drift).
- The 1024 floor turns out to be a deliberate workaround for a Madrid paging/
  ordering quirk (look for a nearby comment or a linked issue). If removing it
  changes result *ordering* (e.g. Madrid returns oldest-first without a limit
  and the floor was compensating), STOP and report — correctness of which
  messages are returned must not regress silently.
- Pushing search into Madrid would require editing the Madrid package — report;
  keep the dependency change out of this plan.

## Maintenance notes

- The over-fetch and the in-memory search are coupled; if a later change adds
  server-side search via Madrid, remove the headroom multiplier entirely.
- Reviewer should confirm the *set* of returned messages for a given query is
  unchanged — this is a performance fix, not a behavior change. Pay special
  attention to ordering (newest-first is the expected contract).
