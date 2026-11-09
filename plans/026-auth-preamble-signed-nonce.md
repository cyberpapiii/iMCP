# Plan 026: Authentication preamble — signed nonce over the existing channel

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 8ff28fe..HEAD -- App/Controllers/NWConnectionTransport.swift App/Controllers/ServerNetworkManager.swift App/Controllers/MCPConnectionManager.swift CLI/main.swift CLI/MessageFrameScanner.swift`
> Re-read cited code on any mismatch; on structural drift, STOP.

## Status

- **Priority**: P1 (security direction)
- **Effort**: L
- **Risk**: MEDIUM-HIGH — touches the transport handshake both sides; a bug
  here breaks every client connection
- **Depends on**: 025 (trust store)
- **Category**: security
- **Planned at**: commit `8ff28fe`, 2026-07-06

## Why this matters

Approval identity today is the client-supplied `clientInfo.name` — display
only, unverifiable. This plan adds cryptographic client identity: the app
challenges each new connection with a nonce; a client holding a paired
private key signs it and is auto-approved; everything else falls through to
the existing manual approval prompt (permanent grace mode — nothing breaks).

## Design constraints (operator decisions, do not relitigate)

- Transport stays Bonjour + TCP; no XPC, no TLS in this plan.
- Auth happens as a **connection preamble** at the framing layer, before MCP
  traffic. Precedent: the channel already carries non-MCP heartbeat frames —
  `App/Controllers/NWConnectionTransport.swift:191-205` strips them, and
  `CLI/MessageFrameScanner.swift` mirrors that on the CLI side. Auth frames
  use the same magic-prefix style so they are unambiguous against MCP JSON
  and against heartbeats, and older peers that do not understand them are
  unaffected (see grace rules below).
- Signature: CryptoKit P-256 (`P256.Signing`). Fingerprint = lowercase hex
  SHA-256 of the raw public key representation — MUST match plan 025's
  documented format exactly.
- CLI private key: Keychain (`kSecClassGenericPassword`, service
  `me.mattt.iMCP.client-key` or similar) in release; when the environment
  variable `IMCP_KEY_FILE` is set (debug/dev), load/store the key at that
  path (0600) instead. Rationale: ad-hoc debug re-signing breaks Keychain
  ACLs; release signing is stable.
- Grace mode is permanent: a connection that never sends an auth frame, or
  fails verification, proceeds exactly as today (manual approval prompt with
  120s TTL). Failed verification must NOT terminate the connection; log and
  fall through.

## Protocol sketch (executor refines details, keeps the shape)

1. On accepting a connection, before the MCP server consumes traffic, the app
   sends one `AUTH-CHALLENGE` frame containing a fresh random 32-byte nonce
   (base64) and a protocol version.
2. The CLI, if it has a keypair, replies with one `AUTH-RESPONSE` frame:
   public key (base64 raw), signature over `nonce || connection-scoped
   context` (include the nonce verbatim; bind context to prevent replay
   across connections).
3. App verifies: signature valid AND fingerprint in `PairedClientStore` →
   mark the connection pre-approved via the existing
   `markConnectionApproved` path (`App/Controllers/ServerNetworkManager.swift:196`)
   once the MCP initialize arrives, skipping the UI prompt (the approval
   handler at `ServerNetworkManager.swift:266` is the integration point —
   short-circuit before invoking the UI handler).
4. Signature valid but fingerprint unknown → remember the verified
   fingerprint on the connection for plan 027's pairing flow; still prompt.
5. No response / invalid → grace: prompt as today. The app must not block
   waiting for an auth frame: proceed the moment the first MCP bytes arrive
   instead.
6. MCP clients that connect directly over TCP (not via the bundled CLI) send
   no auth frames and land in grace mode untouched. The CLI must tolerate an
   app that never sends a challenge (old app build): proxy as today.

## Scope

**In scope**: `NWConnectionTransport.swift` (app-side frame send/strip),
`ServerNetworkManager.swift` + `MCPConnectionManager.swift` (carry verified
fingerprint, short-circuit approval), `CLI/main.swift` +
`CLI/MessageFrameScanner.swift` (respond to challenge, strip auth frames from
the proxied stream), new `CLI` key-management file, new shared frame-format
file(s), tests both sides.

**Out of scope**: pairing UX (027), TLS, Settings changes, removing grace.

## Tests (minimum)

- Frame encode/decode round-trip; auth frames never leak into proxied stdout
  (extend `MessageFrameScanner` tests).
- Signature verify: valid key+nonce passes; wrong nonce, wrong key, replayed
  context all fail.
- Approval short-circuit: paired fingerprint auto-approves (use the existing
  `#if DEBUG` seam pattern in `ServerNetworkManager`); unknown fingerprint
  still requires the handler.
- Grace: connection with no auth frames behaves exactly as current tests
  expect (existing suites must stay green untouched — if an existing approval
  test needs editing, treat as a red flag and justify in the commit message).

## Verification

- Both suites + strict lint.
- Live check: build, reinstall, `plug server disable imcp && plug server
  enable imcp`, confirm Healthy and a tool call round-trips (grace path,
  since no pairing exists yet).

## Done criteria

- [ ] Paired fingerprint auto-approves; no UI prompt.
- [ ] Unpaired/legacy/direct-TCP clients behave exactly as before.
- [ ] Old-app/new-CLI and new-app/old-CLI both degrade to grace cleanly.
- [ ] Tests above pass; suites green; lint clean; live Plug check passes.
- [ ] `plans/README.md` updated.

## STOP conditions

- The MCP Swift SDK transport consumes bytes before the app can inject the
  challenge frame (ordering impossible without SDK changes).
- Keychain access from the CLI requires new entitlements on the app bundle.
- Any existing approval/gating test must be weakened to pass.
