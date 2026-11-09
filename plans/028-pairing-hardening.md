# Plan 028: Pairing hardening — rotation, reset, supportability

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat <plan-027-merge-commit>..HEAD -- App/Controllers/PairedClientStore.swift App/Views/SettingsView.swift CLI/main.swift`

## Status

- **Priority**: P3
- **Effort**: S-M
- **Risk**: LOW-MEDIUM
- **Depends on**: 025–027
- **Category**: security / supportability
- **Planned at**: commit `8ff28fe`, 2026-07-06

## Why this matters

025–027 make pairing work; this plan makes it operable: users can recover
from lost/compromised keys, support can diagnose auth failures, and the
legacy trust remnants are retired.

## Scope

- **Key rotation (CLI)**: `imcp-server --rotate-key` generates a new keypair
  and prints old + new fingerprints. The app treats a rotated key as a new
  client (re-pair via plan 027 paths) — no server-side rotation protocol in
  this pass; document that.
- **Reset pairing (app)**: Settings gains "Unpair All Clients" (calls
  `PairedClientStore.reset`) with a confirmation dialog stating the effect:
  every client returns to per-connection approval.
- **Diagnostics**: auth-preamble outcomes logged at `notice` with distinct,
  greppable messages (challenge sent / verified-paired / verified-unpaired /
  invalid-signature / no-response-grace). Client-facing MCP errors stay
  generic per `App/Controllers/ToolErrorResponse.swift` conventions — never
  echo fingerprints or key material to the MCP client.
- **Legacy retirement**: remove the vestigial name-based `trustedClients`
  storage and its Settings section (`App/Controllers/ServerController.swift:56,101-121`)
  once paired-client UI covers the need. One release note line in README.
- **Docs**: README security section — threat model boundary in two
  sentences (defends against silent cross-application use of iMCP's granted
  permissions by unpaired same-user processes; does not defend against root
  or a fully compromised user account), pairing how-to, reset/rotation
  how-to, Inspector note.

## Out of scope

TLS-PSK / channel encryption — deliberately deferred indefinitely: the
listener is loopback-scoped (`acceptLocalOnly`), so channel encryption adds
the least value of the pairing phases at the highest breakage risk. Revisit
only if the listener ever accepts non-local connections.

## Tests

- Rotation produces a different fingerprint; old key no longer verifies.
- Reset empties the store; next connection prompts.
- Log-message strings asserted where a seam exists; otherwise verified live.

## Verification

Suites + lint + build + live pair/unpair/re-pair cycle with Plug.

## Done criteria

- [ ] Rotation, reset, diagnostics, legacy removal, README all landed.
- [ ] No fingerprint/key material in any client-facing error.
- [ ] Suites green; lint clean; `plans/README.md` updated.

## STOP conditions

- Removing `trustedClients` breaks decoding of existing user defaults in a
  way that crashes Settings (must degrade silently instead).
