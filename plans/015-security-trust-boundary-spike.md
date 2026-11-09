# Plan 015: Security spike — trust boundary between CLI clients and the app

> **This is a DESIGN / SPIKE plan, not a build plan.** The deliverable is a
> written design document plus a proof-of-concept branch that is **not merged**.
> The executor investigates, prototypes narrowly, and writes findings — it does
> **not** ship a security redesign. Any code produced lives on a throwaway branch
> for evaluation and is described in the report, never merged to `main`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- App/Controllers/ServerController.swift CLI/main.swift`
> Re-read the cited code before relying on line numbers below.

## Status

- **Priority**: P1 (security), but scoped as investigation
- **Effort**: L (spike)
- **Risk**: HIGH if built naively — hence a spike first
- **Depends on**: none; informs future build plans
- **Category**: security / architecture
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

iMCP exposes the user's most sensitive personal data — iMessage, Contacts,
Calendar, Reminders, Location, and screen/audio capture — as MCP tools, reachable
by any process that can speak to the app over its local Bonjour service. The
current trust model has four weaknesses that compound:

1. **Trust keyed on a client-supplied name (SECURITY-01)** — approval and the
   trusted-client set are keyed on `clientInfo.name` from the MCP `initialize`
   message, which the client chooses freely. Any local process can present the
   name of a previously-approved client and inherit its approval. There is no
   cryptographic or OS-level identity behind the name.
2. **Plaintext local channel (SECURITY-02)** — the CLI↔app channel over Bonjour
   is not authenticated/encrypted, so identity rests entirely on that spoofable
   name and any local listener can participate.
3. **CLI endpoint selection is loose (SECURITY-03)** — the CLI selects the app
   endpoint by a loose name match and falls back to `results.first!`, so it can
   bind to an unexpected advertiser on the local network/host.
4. **Approval-gate ordering (CORRECTNESS-08)** — `CallTool`/`ListTools` handlers
   are registered right after `server.start` returns, before approval completes;
   approval is enforced only in the `initialize` hook. The window and ordering
   need auditing to confirm no tool call can be serviced pre-approval.

The point of a spike (not a direct build) is that each "obvious" fix has real
trade-offs — TLS on a Bonjour/`NWListener` channel, per-client identity on macOS,
and not breaking the existing Claude Desktop / MCP Inspector UX. Getting this
wrong either fails to close the hole or breaks every user's setup. So: investigate
and design first, prototype narrowly, decide with eyes open.

## Current state (evidence to confirm, not assume)

Re-read each of these and record what you actually find:

- **Name-keyed trust** — `App/Controllers/ServerController.swift`:
  `isClientTrusted` / `addTrustedClient` (`~216-224`), auto-approve
  (`~357-365`), and where `clientInfo.name` from `initialize` feeds trust
  (`~453-459`, `~288`).
- **Handler registration vs approval ordering** — `CallTool`/`ListTools`
  registered right after `server.start` (`~472-473`); approval logic in the
  initialize hook (`~459-467`); `Server` created with default (non-strict) config
  (`~441-447`). Confirm whether a tool call can arrive and be serviced between
  `start` and approval.
- **Transport** — how the app advertises and listens (Bonjour `_mcp._tcp`,
  `local.`; `NWListener`) and whether any TLS/`NWProtocolTLS` or PSK is
  configured. Search `ServerController.swift` and `CLI/main.swift` for
  `NWListener`, `NWParameters`, `tls`, `NWProtocolTLS`.
- **CLI endpoint selection** — `CLI/main.swift` Bonjour browser: the loose
  name-match then `results.first!` fallback (`~540-566`).
- **Prior art in-repo** — check `git log` for any past auth/pairing attempt and
  the entitlements (`App/App.entitlements`) for what the sandbox permits
  (network server/client, keychain access groups).

## This spike's questions to answer

The written design doc (deliverable) must answer each:

1. **Identity**: What is a robust local-client identity on macOS that a peer
   process cannot trivially forge? Evaluate at least: (a) code-signing identity /
   `SecCode` audit-token peer verification over the connection, (b) a pairing
   handshake with a shared secret shown in the app UI (like the AirDrop/`scan a
   code` model), (c) per-client keypair with trust-on-first-use recorded in the
   Keychain. State which is viable inside the App Sandbox and why.
2. **Channel**: Can the `NWListener` channel use TLS (self-signed cert pinned via
   the pairing secret, or `NWProtocolTLS` PSK) without breaking the CLI proxy?
   What changes on the CLI side? Is mutual auth achievable?
3. **Endpoint selection**: How should the CLI unambiguously identify the *right*
   app instance (e.g. verify a pairing fingerprint) instead of `results.first!`?
4. **Approval-gate ordering**: Confirm whether the pre-approval window is
   exploitable. If so, what is the minimal ordering change (register handlers
   only after approval, or make handlers hard-check approval state) that closes
   it without deadlocking the initialize flow?
5. **UX / migration**: What does first-run pairing look like for existing users
   of Claude Desktop and MCP Inspector? What breaks, and what's the migration?
6. **Threat model boundary**: Explicitly state what is and isn't defended. (A
   local same-user process already has broad access on macOS; the goal is to stop
   *silent cross-application* access to iMCP's tools, not to defend against a
   root attacker. Get this framing right — it determines how much is worth
   building.)

## Commands you will need

| Purpose | Command |
|---------|---------|
| Find transport setup | `grep -rn "NWListener\|NWParameters\|NWProtocolTLS\|includePeerToPeer\|NWBrowser" App CLI` |
| Find trust/approval | `grep -rn "clientInfo\|Trusted\|approve\|approval" App/Controllers/ServerController.swift` |
| Entitlements | `grep -rn "keychain\|network" App/App.entitlements App/App.Debug.entitlements` |
| History of auth attempts | `git log --oneline -- App/Controllers/ServerController.swift` |

Read-only investigation. A prototype, if built, goes on a **separate throwaway
branch** (`spike/security-trust-boundary`) and is **never merged** as part of
this plan.

## Scope

**In scope**:
- Reading code, entitlements, and history to confirm the four weaknesses.
- Writing a design document at `plans/notes/015-security-trust-boundary-design.md`
  answering every question above, with a recommended approach, alternatives
  considered, trade-offs, and a phased build proposal (which future numbered
  plans should exist).
- OPTIONALLY: a minimal proof-of-concept on branch `spike/security-trust-boundary`
  demonstrating the hardest unknown (most likely: TLS/PSK on `NWListener` +
  matching CLI client, OR peer audit-token verification). PoC is for learning; it
  is described in the doc and left unmerged.

**Out of scope**:
- Shipping any auth/encryption change to `main`.
- Modifying the existing approval UX for real users.
- Touching `App/Models/` or the service implementations.
- Reproducing any secret/credential values in the doc (there shouldn't be any
  here, but if the investigation surfaces one, reference `file:line` + type only).

## Steps

### Step 1: Confirm the four weaknesses against the live code

For each of SECURITY-01/02/03 and CORRECTNESS-08, open the cited code and write a
2–4 sentence confirmation (or correction) with exact `file:line`. If any is
already mitigated (e.g. a peer check you didn't expect), say so and drop it.

**Verify**: the design doc's "Confirmed weaknesses" section cites real lines.

### Step 2: Answer the six questions

Research each (macOS `Network.framework` TLS/PSK capabilities, `SecCode`/audit-token
peer verification, Keychain access under the App Sandbox with the app's current
entitlements). Cite Apple documentation. For each option, state: viable in
sandbox? UX cost? attacker still bypasses? Record decisively — a recommendation,
not a menu.

**Verify**: every question in "This spike's questions" has a written answer with a
recommendation.

### Step 3: (Optional) Prototype the hardest unknown

On branch `spike/security-trust-boundary`, build the smallest thing that resolves
the biggest uncertainty — e.g. a PSK-TLS `NWListener`/`NWConnection` pair, or an
audit-token peer check on an incoming connection. Measure whether it works and
whether it breaks the CLI proxy. Do **not** merge. Summarize what the PoC proved
or disproved.

**Verify**: if built, the branch exists and the doc records the result; `main`
is untouched (`git status` on `main` clean of PoC code).

### Step 4: Propose the phased build plan

End the doc with a concrete, ordered list of *future* numbered plans (e.g.
"016 — enforce approval before handler registration [small, do first]",
"017 — PSK-TLS channel", "018 — pairing UX + trusted-key store"), each with a
one-paragraph scope and a risk note, sequenced so the cheap high-value fix
(approval ordering) can land independently of the larger transport work.

**Verify**: the doc ends with a numbered, sequenced build proposal.

## Deliverable

`plans/notes/015-security-trust-boundary-design.md` containing:
1. Confirmed weaknesses (with `file:line`).
2. Threat-model boundary (what's defended, what isn't, and why).
3. Answers + recommendation for each of the six questions.
4. PoC results (if built) and the branch name.
5. Phased build proposal (future plan numbers, scope, risk, order).
6. Open questions that still need the maintainer's decision.

## Done criteria

ALL must hold:

- [ ] `plans/notes/015-security-trust-boundary-design.md` exists with all six sections
- [ ] Each of SECURITY-01/02/03 and CORRECTNESS-08 is confirmed or corrected against real `file:line`
- [ ] Every spike question has a recommendation, not just options
- [ ] A phased, ordered build proposal (future plan numbers) is included
- [ ] No changes to `main` (this plan writes only under `plans/`; any PoC is on an
      unmerged `spike/` branch) — `git status` on `main` shows only `plans/` additions
- [ ] No secret values reproduced anywhere
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- The investigation shows a weakness is already mitigated (correct the record,
  don't invent work).
- A "fix" for one weakness would break the Claude Desktop / MCP Inspector UX for
  all users with no migration path — document the conflict; the maintainer
  decides, this plan doesn't force it.
- The App Sandbox entitlements make the recommended identity mechanism infeasible
  — report the entitlement blocker; that reframes the whole approach.

## Maintenance notes

- Keep this as the single source of the security design until the phased build
  plans are written; when they are, cross-link them here.
- The cheapest item (approval-gate ordering, CORRECTNESS-08) is likely a small
  standalone fix worth extracting into its own build plan early, even before the
  transport work — flag it as such in the proposal.
- Reviewer (ideally the maintainer) must sign off on the threat-model boundary
  before any build plan proceeds — the boundary decision drives everything.
