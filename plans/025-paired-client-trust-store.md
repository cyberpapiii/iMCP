# Plan 025: Paired-client trust store (fingerprint-keyed)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 8ff28fe..HEAD -- App/Controllers/ServerController.swift App/Views/SettingsView.swift`
> If in-scope files changed since planning, re-read them before relying on the
> line numbers below; on a structural mismatch, STOP.

## Status

- **Priority**: P1 (security direction)
- **Effort**: M
- **Risk**: LOW — data model + UI only; no behavior change to approval flow
- **Depends on**: none (first pairing phase)
- **Category**: security
- **Planned at**: commit `8ff28fe`, 2026-07-06
- **Design source**: `plans/notes/015-security-trust-boundary-design.md`
  (recommendation 6) plus operator decisions of 2026-07-06: Keychain for CLI
  keys with debug file fallback, permanent grace mode, keep Bonjour (no XPC),
  pairing optional with per-connection approval as the floor.

## Why this matters

Durable client trust must be keyed on a public-key fingerprint the client
proves possession of, not a client-supplied name. Plan 016 removed name-based
auto-trust; this plan introduces the replacement store that plans 026–027
will authenticate against. It lands first because it is pure model + Settings
UI and unblocks both later plans.

## Current state

- `App/Controllers/ServerController.swift:56` — `@AppStorage("trustedClients")
  private var trustedClientsData = Data()`; accessors at `:101-121`
  (`trustedClients` computed set, `addTrustedClient`, `getTrustedClients`,
  `resetTrustedClients`). Since plan 016 nothing consults these for approval —
  they are vestigial storage surfaced in Settings as legacy data.
- `App/Views/SettingsView.swift` — shows the legacy trusted-client list;
  re-read for the current copy before editing.

## Scope

**In scope**:

- New `App/Models/PairedClient.swift`: `struct PairedClient: Codable,
  Identifiable, Equatable` with `fingerprint: String` (lowercase hex SHA-256 of
  the client's DER/raw public key — document the exact format in a doc
  comment; plans 026–027 must produce the identical derivation), `label:
  String`, `addedAt: Date`. `id` is the fingerprint.
- New `App/Controllers/PairedClientStore.swift`: `@MainActor final class` (or
  a small struct owned by `ServerController`) persisting `[PairedClient]` as
  JSON in `@AppStorage("pairedClients")`. API: `all()`, `contains(fingerprint:)`,
  `add(_:)` (idempotent by fingerprint), `remove(fingerprint:)`, `reset()`.
  Fingerprints are not secrets; UserDefaults is fine.
- Settings UI: a "Paired Clients" section listing label + truncated
  fingerprint + added date, with per-row Remove and a Reset All. Keep the
  legacy name list, retitled as inactive legacy entries with a Clear button
  (wired to existing `resetTrustedClients`).
- Unit tests `iMCPTests/PairedClientStoreTests.swift`: add/idempotent-add/
  remove/reset/contains round-trip through the JSON encoding. Model the test
  around injectable storage (e.g. init taking a `UserDefaults` suite or a
  data get/set closure) so tests do not pollute real defaults.

**Out of scope**: any change to the approval flow, `ServerNetworkManager`,
the CLI, or key generation. No entry in this plan reads or writes Keychain.

## Git workflow

- Branch: `advisor/025-paired-client-trust-store` from current `main`.
- Do NOT push or open a PR unless the operator asks.

## Steps

1. Add `PairedClient` model + `PairedClientStore` with injectable storage.
2. Add Settings section (paired list + legacy cleanup copy).
3. Tests.
4. `swift format -i -r .` then `swift format lint --strict --recursive .`;
   build; `xcodebuild test -scheme iMCP -destination "platform=macOS"`.
   (Quit any installed running iMCP.app first — bundle ID collision breaks
   the test runner.)

## Done criteria

- [ ] Store API exactly as scoped; fingerprint format documented in code.
- [ ] Settings shows paired clients and legacy section; removal/reset work.
- [ ] New tests pass; full suite green; strict lint clean.
- [ ] `plans/README.md` row updated.

## STOP conditions

- `trustedClients` storage is consulted anywhere for approval decisions
  (would contradict plan 016 — investigate before proceeding).
- Persisting via `@AppStorage` requires observable-object gymnastics that
  force changes outside scoped files.
