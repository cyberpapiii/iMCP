# Plan 003: README capability list and tool count reflect the actual services

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- README.md App/Services`
> If `README.md` or the service files changed since this plan was written,
> re-derive the counts in Step 1 before editing; on a mismatch with the numbers
> below, use the freshly derived numbers.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

The README's Capabilities table lists 7 services and tells users they should
"see 🔨12" tools in Claude Desktop, but the app actually ships **10 services**
and **29 tools**. Three shipped services — Shortcuts, Capture (screen/audio
capture), and Utilities — are entirely absent from the README. Stale docs here
are worse than missing: a user whose tool count doesn't match "12" reasonably
concludes the connection is broken, and two headline features (Shortcuts and
screen/audio Capture) are invisible to anyone evaluating the project — Capture
especially has privacy implications a prospective user should understand before
granting permission. After this plan the README matches reality and avoids a
hard-coded count that will drift again.

## Current state

- `README.md` — the Capabilities table is at `README.md:14-64` (7 rows:
  Calendar, Contacts, Location, Maps, Messages, Reminders, Weather). The stale
  count is at `README.md:180` ("you should now see 🔨12 in the bottom right").
- `App/Services/` contains 10 service files. Verified tool counts (number of
  `Tool(` definitions per file at commit `b84f266`):

  | Service | Tools |
  |---------|-------|
  | Calendar | 3 |
  | Capture | 3 |
  | Contacts | 4 |
  | Location | 3 |
  | Maps | 5 |
  | Messages | 1 |
  | Reminders | 3 |
  | Shortcuts | 2 |
  | Utilities | 1 |
  | Weather | 4 |
  | **Total** | **29** |

  Missing from the README table: **Shortcuts**, **Capture**, **Utilities**.

The existing table rows use this structure (from `README.md:14-28`):

```html
  <tr>
    <th>
      <img src="Assets/contacts.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Contacts</strong></td>
    <td>Access contact information about yourself and search your contacts by name, phone number, or email address.</td>
  </tr>
```

Note rows reference icon SVGs in `Assets/` (e.g. `Assets/contacts.svg`). Before
adding a row that references a new icon, confirm the asset exists.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Re-derive tool counts | `grep -rc "Tool(" App/Services/*.swift` | per-file counts |
| List available icons | `ls Assets/*.svg` | list of svg files |

This plan changes only Markdown; no build or format step is required. (`swift
format` does not touch `README.md`.)

## Scope

**In scope**:
- `README.md`

**Out of scope**:
- Any `.swift` file or `Assets/` — do not add or rename icons; if an icon for a
  new service is missing, use a row without an `<img>` or reuse an existing
  generic asset, and note it in your report.
- The Getting Started / Technical Details prose beyond the two edits below.

## Steps

### Step 1: Re-derive the counts (guard against drift)

Run `grep -rc "Tool(" App/Services/*.swift` and sum them. Confirm the total and
the per-service breakdown. If they differ from the table above, use your fresh
numbers throughout the rest of this plan and note the difference in your report.

**Verify**: your computed total is a single number (29 at plan-writing time).

### Step 2: Add the three missing services to the Capabilities table

Add table rows for **Capture**, **Shortcuts**, and **Utilities**, matching the
existing row structure. Suggested copy (adjust to match the tools' actual
descriptions in the service files):

- **Capture** — "Capture screenshots of the screen, windows, or applications,
  take photos from the camera, and record short audio clips." (Read
  `App/Services/Capture.swift` tool descriptions to confirm wording; call out
  that these require screen-recording / camera / microphone permission.)
- **Shortcuts** — "List and run Shortcuts on your Mac, optionally passing text
  input." (See `App/Services/Shortcuts.swift`.)
- **Utilities** — describe from `App/Services/Utilities.swift`'s single tool.

For icons: run `ls Assets/*.svg`; if a matching icon exists use it, otherwise
omit the `<img>` for that row and note it.

**Verify**: `grep -c "<strong>" README.md` reflects 10 service rows (was 7).

### Step 3: Replace the hard-coded tool count

At `README.md:180`, replace the specific "🔨12" phrasing with a
non-numeric description so it can't drift, e.g.:

> After approving the connection, you'll see a hammer icon (🔨) with a tool
> count in the bottom right corner of your chat box. Click it to see all the
> tools iMCP makes available (the exact number depends on which services you've
> enabled).

**Verify**: `grep -n "🔨12" README.md` → no matches.

## Test plan

Docs only — no automated test. Verification is the two `grep` checks above plus
a visual read of the rendered table (confirm 10 rows, correct descriptions).

## Done criteria

ALL must hold:

- [ ] `grep -n "🔨12" README.md` returns no matches
- [ ] Capture, Shortcuts, and Utilities each have a Capabilities row
- [ ] `grep -c "<strong>" README.md` shows 10 service rows
- [ ] No non-Markdown files modified (`git status` shows only `README.md`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- The service count derived in Step 1 is not 10, or the tool total is far from
  29 (the codebase has changed materially — re-scope with the operator).
- A service's tools are gated behind a build flag such that they don't ship in
  release (e.g. Weather is behind `WEATHERKIT_AVAILABLE`) — if any of the three
  services you're adding turn out to be conditionally compiled, note it and ask
  before implying they're always present.

## Maintenance notes

- Because Step 3 removes the numeric count, future service additions only need a
  new table row, not a count edit.
- Reviewer should confirm the Capture row mentions the sensitive permissions it
  needs — this is the user's first warning about screen/audio capture.
- Consider (deferred) generating the capability list from the service registry
  so it can never drift; out of scope here.
