# Plan 002: `reminders_fetch` applies its date range and bounds its result set

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- App/Services/Reminders.swift`
> If `App/Services/Reminders.swift` changed since this plan was written, compare
> the "Current state" excerpt against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

When `reminders_fetch` is called without a `completed` argument (the common
default), it uses `predicateForReminders(in:)`, which fetches **every reminder
in the selected lists** — completed items from years back included — and the
`start`/`end` date arguments the tool parses are silently ignored on that path.
The full set is then serialized into JSON-LD and returned to the LLM client.
The cost is large token bloat for the client and unnecessary memory/CPU in the
app, and the behavior contradicts the tool's own schema (which advertises date
filtering). After this plan, the default path honors the parsed date range and
the result set is bounded.

## Current state

- `App/Services/Reminders.swift` — Reminders service; the `reminders_fetch` tool.

The parsed dates (`startDate`, `endDate`) are computed at
`App/Services/Reminders.swift:125-151` and correctly normalized. They are used
in the completed/incomplete branches but **not** in the `else` (default) branch.

Current code, `App/Services/Reminders.swift:153-193`:

```swift
// Create predicate based on completion status
let predicate: NSPredicate
if case .bool(let completed) = arguments["completed"] {
    if completed {
        predicate = self.eventStore.predicateForCompletedReminders(
            withCompletionDateStarting: startDate,
            ending: endDate,
            calendars: reminderLists
        )
    } else {
        predicate = self.eventStore.predicateForIncompleteReminders(
            withDueDateStarting: startDate,
            ending: endDate,
            calendars: reminderLists
        )
    }
} else {
    // If completion status not specified, use incomplete predicate as default
    predicate = self.eventStore.predicateForReminders(in: reminderLists)  // <-- ignores dates, returns everything
}

// Fetch reminders
let reminders = try await withCheckedThrowingContinuation { continuation in
    self.eventStore.fetchReminders(matching: predicate) { fetchedReminders in
        continuation.resume(returning: fetchedReminders ?? [])
    }
}

// Apply additional filters
var filteredReminders = reminders

// Filter by search text if provided
if case .string(let searchText) = arguments["query"],
    !searchText.isEmpty
{
    filteredReminders = filteredReminders.filter {
        $0.title?.localizedCaseInsensitiveContains(searchText) == true
    }
}

return filteredReminders.map { PlanAction($0) }
```

Note the comment on the `else` branch ("use incomplete predicate as default")
does not match what `predicateForReminders(in:)` actually does — that API
returns all reminders regardless of completion or date.

Read the tool's `inputSchema` (search upward in the same tool for the
`properties:` block) to see how `start`, `end`, `completed`, `query`, and any
`limit` argument are declared, so your default-branch behavior matches the
documented contract.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format (write) | `swift format -i -r .` | exit 0 |
| Format lint (CI gate) | `swift format lint --strict --recursive .` | exit 0, no output |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**:
- `App/Services/Reminders.swift`

**Out of scope**:
- `App/Extensions/Foundation+Extensions.swift` — date normalization helpers are correct.
- The completed/incomplete branches — they already apply the dates correctly.
- The `query`/search post-filter — leave it as-is.

## Git workflow

- Branch: `advisor/002-fix-reminders-date-filter`
- Single commit; short imperative message (e.g. "Apply date range and result
  cap to reminders_fetch default path").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Make the default branch honor the date range

Replace the `else` branch so a call without `completed` uses the incomplete
predicate with the parsed dates (matching the branch's own comment and the tool
schema), rather than the unbounded `predicateForReminders(in:)`.

Target shape:

```swift
} else {
    // No completion status specified: default to incomplete reminders in range.
    predicate = self.eventStore.predicateForIncompleteReminders(
        withDueDateStarting: startDate,
        ending: endDate,
        calendars: reminderLists
    )
}
```

`startDate`/`endDate` are `Date?`; passing `nil` for either is valid and means
"unbounded on that side," so callers that omit dates still work.

**Verify**: `grep -n "predicateForReminders(in:)" App/Services/Reminders.swift`
→ no matches remain.

### Step 2: Bound the result set

After the `query` post-filter and before `return filteredReminders.map { PlanAction($0) }`,
apply a cap. Add a `limit` read near the other argument parsing (mirror how
`messages_fetch` reads `limit` in `App/Services/Messages.swift:120`), defaulting
to a sensible bound, and apply `.prefix(limit)`:

```swift
let limit = arguments["limit"]?.intValue ?? 100
return filteredReminders.prefix(limit).map { PlanAction($0) }
```

If the tool's `inputSchema` does not already declare a `limit` property, add one
to the schema mirroring the `messages_fetch` declaration
(`App/Services/Messages.swift:75-78`) so the cap is discoverable by clients.

**Verify**: `grep -n "prefix(" App/Services/Reminders.swift` → shows the new cap.

### Step 3: Format and build

Run `swift format -i -r .` then build.

**Verify**: build prints `** BUILD SUCCEEDED **`; `swift format lint --strict --recursive .` exits 0.

## Test plan

No App-side unit-test target exists yet (plan 014 establishes one). Manual
reasoning to record in your report:
- A call with no `completed` and `start`/`end` set now returns only incomplete
  reminders due within the range, capped at the limit.
- A call with no arguments returns incomplete reminders (unbounded dates),
  capped at the limit — not the entire completed history.
If an App test target exists (plan 014 landed), add a test that a default-args
fetch does not include a completed reminder; otherwise note the deferral.

## Done criteria

ALL must hold:

- [ ] `predicateForReminders(in:)` no longer appears in `App/Services/Reminders.swift`
- [ ] The default branch passes `startDate`/`endDate` to `predicateForIncompleteReminders`
- [ ] A result cap (`prefix`) is applied; `limit` is a declared schema property
- [ ] `xcodebuild ... build` prints `** BUILD SUCCEEDED **`
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] No files outside `App/Services/Reminders.swift` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- The predicate block doesn't match the "Current state" excerpt (drift).
- Changing the default predicate breaks compilation because the EventKit API
  signature differs from what's shown (re-check the completed/incomplete
  branches, which already call these APIs successfully).
- You discover a product reason the default was intentionally "return
  everything" (e.g. a comment or doc elsewhere) — report before changing.

## Maintenance notes

- This aligns the default path with the incomplete branch. If a future
  requirement needs "all reminders including completed," add an explicit
  argument for it rather than reverting to the unbounded predicate.
- Reviewer should confirm the `limit` default is reasonable for LLM context
  budgets and that omitting `start`/`end` still returns useful results.
