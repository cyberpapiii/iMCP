# Plan 005: Add CLAUDE.md / AGENTS.md and a build-from-source section

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- README.md .github/workflows/ci.yml .swift-format`
> If these changed since this plan was written, re-derive the exact build/test/
> format commands from the live files before writing the docs.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (but the commands it documents are validated by plan 004)
- **Category**: dx
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

Agents already operate in this repo — `.cursor/rules/ignore-sourcekit-warnings.mdc`
exists precisely because an AI tool needed a repo-specific quirk documented — yet
there is no `CLAUDE.md`/`AGENTS.md`. Every agent session re-derives the build
command, scheme names, and the strict-format requirement, or gets them wrong: CI
lints `swift format --strict`, so an agent that doesn't format before committing
fails CI on whitespace, and commit `2e8e048` ("swift format -i -r .") shows the
formatting drift already had to be mass-corrected once. Separately, a human
contributor has no documented way to build from source — the required toolchain
is only discoverable by reading the CI YAML. After this plan, both agents and
contributors have a single authoritative reference.

## Current state

- No `CLAUDE.md`, `AGENTS.md`, or `CONTRIBUTING.md` at the repo root.
- `.cursor/rules/ignore-sourcekit-warnings.mdc` exists — read it; it documents
  that SourceKit emits spurious "cannot find type" warnings that should be
  ignored. This caveat belongs in the agent doc.
- Authoritative commands (verified during recon):
  - Build: `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build`
  - Test: `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"`
  - Format (write): `swift format -i -r .`
  - Format lint (CI gate): `swift format lint --strict --recursive .`
  - `.swift-format` config: 4-space indentation, 120-column line length,
    `AlwaysUseLowerCamelCase` disabled.
- Toolchain (from `.github/workflows/ci.yml:12-24`): macOS 26 runner,
  Xcode 26.0. Debug builds without a provisioning profile (commit `deff5dd`).
- Architecture (from `README.md:244-269`): the app (`App/`) hosts the UI and
  system-permission access; the bundled CLI `imcp-server` (`CLI/`) is an MCP
  stdio server that discovers the app over Bonjour (`_mcp._tcp`, domain `local.`)
  and proxies requests. The CLI does nothing without the app running and at
  least one service enabled.
- Release automation lives in `Scripts/release.sh`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Confirm build works | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | `** BUILD SUCCEEDED **` |
| Confirm format lint clean | `swift format lint --strict --recursive .` | exit 0, no output |

Docs-only change; no code build required to *write* the files, but run the two
commands above once to confirm the commands you're documenting actually work.

## Scope

**In scope** (create):
- `CLAUDE.md`
- `AGENTS.md`
- Optionally a "Building from source" section appended to `README.md`, OR a new
  `CONTRIBUTING.md` — pick one (README section preferred, since the README is
  where contributors already look).

**Out of scope**:
- Any `.swift` file, `.github/`, or `Scripts/`.
- Changing `.cursor/rules/` — reference it, don't move it.

## Steps

### Step 1: Write CLAUDE.md

Create `CLAUDE.md` covering, concisely:

- One-paragraph architecture: the App + CLI/Bonjour relationship (see Current
  state); note the CLI is inert without the app running and a service enabled.
- Build / test / format commands exactly as listed in Current state, in a code
  block, labeled.
- Formatting is enforced: CI runs `swift format lint --strict`; always run
  `swift format -i -r .` before committing. `.swift-format` = 4-space, 120 cols.
- Warnings are treated as errors — a warning will fail the build.
- The SourceKit caveat from `.cursor/rules/ignore-sourcekit-warnings.mdc`
  (spurious "cannot find type" warnings can be ignored).
- Key directories: `App/Services/` (one file per MCP service),
  `App/Controllers/ServerController.swift` (network + MCP core),
  `CLI/main.swift` (stdio↔Bonjour proxy), `App/Models/` (Tool/Service/Value).
- Release automation: `Scripts/release.sh`.
- A pointer: "Improvement plans for this repo live in `plans/` — read the
  relevant plan fully before implementing."

**Verify**: `test -f CLAUDE.md && grep -c "swift format" CLAUDE.md` → file exists,
≥1 match.

### Step 2: Mirror to AGENTS.md

Create `AGENTS.md` with the same content. To avoid divergence, `AGENTS.md` may be
a short pointer file:

```markdown
# AGENTS.md

This project's agent and contributor guidance lives in [CLAUDE.md](CLAUDE.md).
```

Pick either a full mirror or the pointer form; the pointer is preferred to keep a
single source of truth.

**Verify**: `test -f AGENTS.md` → exists.

### Step 3: Document building from source

Add a "Building from source" subsection (in `README.md` under Technical Details,
or in a new `CONTRIBUTING.md`) covering: prerequisites (macOS 26 / Xcode 26),
open `iMCP.xcodeproj`, build/run the `iMCP` scheme, that Debug builds need no
provisioning profile, and how to exercise the pair locally (enable a service in
the menu bar, then point the MCP Inspector or Claude Desktop at the built
`imcp-server` — cross-reference the existing Debugging section at
`README.md:323-364`).

**Verify**: `grep -rn "Building from source\|## Building" README.md CONTRIBUTING.md 2>/dev/null` → shows the new section.

## Test plan

Docs only. Verification is the existence/`grep` checks above plus a read-through
confirming every command in the docs matches the ones validated in "Commands you
will need."

## Done criteria

ALL must hold:

- [ ] `CLAUDE.md` exists and documents build, test, format (with `--strict`
      note), the warnings-as-errors and SourceKit caveats, and the App+CLI
      architecture
- [ ] `AGENTS.md` exists (full mirror or pointer to CLAUDE.md)
- [ ] A build-from-source section exists in `README.md` or `CONTRIBUTING.md`
- [ ] Every command in the docs matches those in "Commands you will need"
- [ ] No `.swift` or CI files modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- The build or format-lint command in "Commands you will need" does not succeed
  as documented (the commands are wrong — fix the doc to match reality and note
  the discrepancy).
- `.cursor/rules/ignore-sourcekit-warnings.mdc` no longer exists or says
  something different from the summary above (re-read and document what it
  actually says).

## Maintenance notes

- Keep `CLAUDE.md` as the single source; if `AGENTS.md` is a full mirror instead
  of a pointer, update both together.
- When plan 004 adds the CI test step and plan 014 adds an App test target,
  update the test command(s) in `CLAUDE.md`.
- Reviewer should verify the documented commands are copy-pasteable and correct.
