# Plan 027: Pairing UX — one-time code, approval-prompt pairing, CLI bootstrap

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat <plan-026-merge-commit>..HEAD -- App/Controllers/ServerController.swift App/Views/ConnectionApprovalView.swift App/Views/ContentView.swift CLI/main.swift`
> Fill in the 026 merge commit before starting; re-read cited code on drift.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MEDIUM — touches user-facing setup
- **Depends on**: 025, 026
- **Category**: security / UX
- **Planned at**: commit `8ff28fe`, 2026-07-06

## Why this matters

026 gives paired clients silent approval but no way to become paired. This
plan adds the two enrollment paths the operator chose: (a) inline pairing
from the approval prompt for connections that proved key possession, and
(b) a one-time pairing code for persistent non-CLI clients (MCP Inspector,
direct-TCP clients). Pairing stays optional; per-connection approval remains
the permanent floor.

## Scope

**Path A — approval-prompt pairing (primary, zero-friction):**

- 026 leaves a verified-but-unknown fingerprint on the connection. Surface it
  in the approval window (`App/Views/ConnectionApprovalView.swift`) as a
  "Always allow this client (pair)" checkbox, default OFF, shown ONLY when a
  verified fingerprint exists. Approve with the box checked → `PairedClientStore.add`
  with the client name as label. The window shows the truncated fingerprint so
  the user is approving a key, not a name.
- Connections with no verified fingerprint (direct TCP, legacy) must NOT show
  the checkbox — pairing by unverified name is exactly what plan 016 removed.

**Path B — one-time pairing code (for clients that cannot run the preamble
automatically, or headless setups):**

- Menu item "Pair a Client…" (menu bar extra, near "Configure Claude
  Desktop"): generates a 6–8 character one-time code, displays it with a
  5-minute expiry, single use, stored in memory only.
- CLI: `imcp-server --pair <code>` (and env `IMCP_PAIR_CODE` for spawned
  contexts) includes the code in its 026 `AUTH-RESPONSE`. App: valid code +
  valid signature → auto-add fingerprint to the store (no prompt), consume
  the code.
- Document the direct-TCP client story in README (a short "Pairing" section):
  such clients either implement the preamble + code, or live with the
  approval prompt.

**CLI bootstrap:** first run without key material generates the keypair
(Keychain, or `IMCP_KEY_FILE` in debug per 026) transparently — no user
action. `imcp-server --fingerprint` prints the fingerprint and exits, for
support and manual verification.

**Out of scope**: TLS, key rotation (028), any change to the grace path.

## Tests (minimum)

- Pairing-code lifecycle: single use, expiry, wrong code rejected (pure logic
  — extract a `PairingCodeIssuer` type, test without UI).
- Approve-with-pair adds to store; approve-without-pair does not; deny never
  does. (Extend `ConnectionApprovalQueue`/controller seam tests.)
- CLI `--fingerprint` output matches the 025 fingerprint derivation.

## Verification

- Suites + lint + build.
- Live: reinstall app, restart Plug's imcp server, approve once with the pair
  checkbox, then `plug server disable imcp && plug server enable imcp` and
  confirm the reconnection produces NO approval prompt.

## Done criteria

- [ ] Pair-on-approve works end to end with the bundled CLI (verified live).
- [ ] One-time code path works; codes are single-use and expire.
- [ ] Unverified connections never see a pairing affordance.
- [ ] README documents pairing incl. the Inspector/direct-TCP story.
- [ ] Tests pass; suites green; lint clean; `plans/README.md` updated.

## STOP conditions

- Path A requires weakening the 021 approval-spine reentrancy behavior
  (close-before-answer, deferred presentation, stale-callback guard). The
  checkbox must ride the existing approve callback, not add a new resume path.
- Code display requires a new window controller that conflicts with the
  approval window lifecycle.
