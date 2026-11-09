# Plan 001: `events_create` uses the correct end-date normalization for date-only ends

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- App/Services/Calendar.swift`
> If `App/Services/Calendar.swift` changed since this plan was written, compare the
> "Current state" excerpt against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

`events_create` collapses a date-only end date to local midnight (`startOfDay`),
so an event created with a date-only range like start `"2026-07-10"` / end
`"2026-07-10"` gets a zero-duration end (start == end), and any date-only end
equal to or before the start produces a zero- or negative-duration event. The
sibling `events_fetch` handles the same situation correctly by treating a
date-only end as the *start of the next day*. The two code paths disagree on
what a date-only end means, and the create path is wrong. After this plan,
creating an event from a date-only range yields a sensible duration consistent
with fetch semantics.

## Current state

- `App/Services/Calendar.swift` — the Calendar service; `events_create` tool.
  The bug is in how the end date is normalized.

Current code, `App/Services/Calendar.swift:388-396`:

```swift
let calendar = Calendar.current
let startDate = calendar.normalizedStartDate(
    from: parsedStart.date,
    isDateOnly: parsedStart.isDateOnly
)
let endDate = calendar.normalizedStartDate(   // <-- BUG: should be normalizedEndDate
    from: parsedEnd.date,
    isDateOnly: parsedEnd.isDateOnly
)
```

The two helpers, defined in `App/Extensions/Foundation+Extensions.swift:102-115`:

```swift
func normalizedStartDate(from date: Date, isDateOnly: Bool) -> Date {
    isDateOnly ? startOfDay(for: date) : date
}

func normalizedEndDate(from date: Date, isDateOnly: Bool) -> Date {
    guard isDateOnly else { return date }
    let startOfDay = startOfDay(for: date)
    return self.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
}
```

The correct pattern is already used by `events_fetch` at
`App/Services/Calendar.swift:159-162` (uses `normalizedEndDate` for the end).

Note the all-day branch immediately below the bug (`Calendar.swift:398-409`)
independently recomputes start/end components for `isAllDay == true` events, so
this fix targets the **non-all-day** path. Read lines 398-430 before editing to
confirm the all-day branch overrides `endDate` and is therefore unaffected.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format (write) | `swift format -i -r .` | exit 0 |
| Format lint (CI gate) | `swift format lint --strict --recursive .` | exit 0, no output |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | `** BUILD SUCCEEDED **` |

This project treats warnings as errors and CI runs `swift format lint --strict`.
Always run `swift format -i -r .` before finishing.

## Scope

**In scope** (the only file you should modify):
- `App/Services/Calendar.swift`

**Out of scope** (do NOT touch):
- `App/Extensions/Foundation+Extensions.swift` — the helpers are correct; only
  the *call site* chose the wrong one.
- The all-day branch logic (`Calendar.swift:398-430`) — it already sets end to
  23:59:59 of the end day and must keep doing so.
- `events_fetch` — already correct.

## Git workflow

- Branch: `advisor/001-fix-event-end-date`
- Single commit; message style matches repo history (short imperative, e.g.
  "Fix events_create end-date normalization for date-only ranges").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Change the end-date normalization call

In `App/Services/Calendar.swift`, in the `events_create` tool implementation,
change the `endDate` assignment (currently at ~line 393) from
`calendar.normalizedStartDate(...)` to `calendar.normalizedEndDate(...)`:

```swift
let endDate = calendar.normalizedEndDate(
    from: parsedEnd.date,
    isDateOnly: parsedEnd.isDateOnly
)
```

Leave the `startDate` line (using `normalizedStartDate`) unchanged.

**Verify**: `grep -n "normalizedEndDate\|normalizedStartDate" App/Services/Calendar.swift`
→ the `events_create` block now shows `normalizedStartDate` for start and
`normalizedEndDate` for end; `events_fetch` still shows one of each.

### Step 2: Format and build

Run `swift format -i -r .` then the build.

**Verify**: `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build`
→ `** BUILD SUCCEEDED **`. Then `swift format lint --strict --recursive .` → no output, exit 0.

## Test plan

There is no App-side unit-test target today (plan 014 establishes one), so an
automated test for this specific fix cannot be added without that infrastructure.
Do NOT create a new target in this plan.

- Manual verification (record the result in your report): reason through the
  values. For start `"2026-07-10"` (date-only) and end `"2026-07-11"`
  (date-only), non-all-day: `startDate` = 2026-07-10 00:00 local, `endDate` =
  2026-07-12 00:00 local (next day after the 11th). Confirm the edited code
  produces this by re-reading the two helper definitions.
- If plan 014 (which establishes the App test target) has already landed, add one
  test asserting `events_create`'s end normalization; otherwise note in your
  report that the automated test is deferred to plan 014.

## Done criteria

ALL must hold:

- [ ] `App/Services/Calendar.swift` `events_create` uses `normalizedEndDate` for the end date
- [ ] `xcodebuild ... build` prints `** BUILD SUCCEEDED **`
- [ ] `swift format lint --strict --recursive .` exits 0 with no output
- [ ] No files outside `App/Services/Calendar.swift` are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The `events_create` code at `Calendar.swift:388-396` doesn't match the
  "Current state" excerpt (the file has drifted).
- The build fails for a reason unrelated to this one-line change.
- You find the all-day branch also depends on `endDate` being `startOfDay`
  in a way this change breaks (re-read lines 398-430 to check).

## Maintenance notes

- If the date-only semantics for events are ever revisited, keep `events_create`
  and `events_fetch` consistent — they should agree that a date-only end means
  "through the end of that day."
- Reviewer should confirm the all-day path still yields a whole-day event and
  the timed path now yields a positive duration for date-only ranges.
- Deferred: an automated regression test, which belongs with the App test
  target introduced in plan 014.
