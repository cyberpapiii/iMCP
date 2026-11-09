# Security Trust-Boundary Design

Status: design spike complete. No proof-of-concept branch was built.

## Confirmed Weaknesses

The plan's drift command only compares committed `HEAD` against `b84f266`; this
branch also has live worktree changes from plans 016 and 017, so the files below
were re-read directly.

SECURITY-01, name-keyed persistent trust: corrected in this branch. The old
`isClientTrusted` / `addTrustedClient` auto-approval path is gone. Approval UI
state is now queued per connection UUID in `App/Controllers/ServerController.swift:25`
through `App/Controllers/ServerController.swift:33`, and the async approval
bridge passes the connection UUID through `App/Controllers/ServerController.swift:166`
through `App/Controllers/ServerController.swift:193`. The client-supplied
`clientInfo.name` is still used for display only at
`App/Controllers/ServerController.swift:185`, so it is not a durable identity.

SECURITY-02, plaintext local channel: still present. The app listener uses plain
TCP parameters with `acceptLocalOnly = true` and no `NWProtocolTLS` in
`App/Controllers/NetworkDiscoveryManager.swift:14` through
`App/Controllers/NetworkDiscoveryManager.swift:27`; restart uses the same plain
TCP setup in `App/Controllers/NetworkDiscoveryManager.swift:61` through
`App/Controllers/NetworkDiscoveryManager.swift:74`. The CLI uses plain
`NWParameters.tcp` at `CLI/main.swift:17` through `CLI/main.swift:31`. This is
local-host scoped by `acceptLocalOnly`, but any same-user local process can still
attempt to speak the protocol.

SECURITY-03, loose CLI endpoint selection: mostly corrected in this branch. The
CLI now requires exactly one Bonjour endpoint whose description contains `iMCP`
and throws on zero or multiple candidates at `CLI/main.swift:472` through
`CLI/main.swift:485`; the previous `results.first!` fallback is gone. This is
still name-based discovery, not cryptographic endpoint identity.

CORRECTNESS-08, handler registration before approval: corrected in this branch.
`MCPConnectionManager.start` awaits approval inside the MCP initialize closure at
`App/Controllers/MCPConnectionManager.swift:41` through
`App/Controllers/MCPConnectionManager.swift:55`, and registers tool handlers only
after `server.start` returns at `App/Controllers/MCPConnectionManager.swift:60`
through `App/Controllers/MCPConnectionManager.swift:61`. A defense-in-depth
handler-level approval check would still be useful, but the original pre-approval
handler window is not present in the live code.

## Threat Model Boundary

iMCP should defend against silent cross-application use of its enabled tools by
an unpaired local process. That includes a same-user app pretending to be Claude
Desktop, advertising a confusing Bonjour endpoint, or replaying a client name.

iMCP should not claim to defend against root, a compromised user account, direct
TCC database tampering, screen/keychain exfiltration by privileged malware, or a
user intentionally approving a malicious client. A same-user process already has
broad macOS attack surface; the target is narrower: make iMCP's high-value MCP
tools require explicit pairing and cryptographic proof of that pairing.

## Questions And Recommendations

1. Identity: code-signing identity is robust when the transport exposes a peer
   audit token or XPC peer requirement. Apple documents code signing as the
   platform identity mechanism, and Apple DTS recommends XPC peer code-signing
   requirements for XPC. However, the current `NWConnection` transport does not
   expose the peer process audit token, so a SecCode-only solution is not viable
   without moving local IPC to XPC or adding a signed helper. Recommendation:
   keep Network.framework for MCP transport and implement app-approved
   per-client keypairs. Use the app UI for first pairing, store trusted client
   public-key fingerprints in the app, and require each later connection to sign
   an app nonce during initialize.

2. Channel: Network.framework can use TLS over TCP with `NWProtocolTLS.Options`
   and Security protocol options; Apple documents PSK configuration through
   `sec_protocol_options_add_pre_shared_key`, and Apple's Network framework
   guidance calls TLS-PSK a practical peer-to-peer option. Recommendation: phase
   this after keypair pairing. First authenticate the client at the MCP layer;
   then upgrade to TLS-PSK or a pinned local certificate derived from the paired
   secret. PSK gives mutual possession proof and avoids a local CA, but it needs
   careful secret provisioning and rotation.

3. Endpoint selection: Bonjour names and TXT records are advisory, not identity.
   Recommendation: persist an app instance fingerprint during pairing, advertise
   that fingerprint in Bonjour TXT only as a selector, and require the CLI to
   verify the selected endpoint cryptographically during the TLS or MCP nonce
   handshake. CLI behavior should be fail-closed: zero matches, multiple matches,
   or fingerprint mismatch all abort.

4. Approval-gate ordering: the live branch registers handlers after approval, so
   the cheap critical fix is already present. Recommendation: keep this ordering
   and add a small defense-in-depth guard in `registerHandlers` that refuses
   `ListTools` and `CallTool` if the connection UUID is not in an
   actor-owned approved set. That makes future refactors less likely to reopen
   the window.

5. UX and migration: existing users should be asked to re-run "Set Up iMCP
   Server". Setup should generate or reuse a paired client key, write only the
   minimal bootstrap material needed by `imcp-server`, and show a one-time
   approval prompt in the app. MCP Inspector needs a manual pairing path: show a
   short code or pasteable pairing command, then record the resulting client
   fingerprint. Legacy trusted-client names should remain visible as inactive
   cleanup data only, matching the current Settings copy.

6. Recommended design: app-approved per-client keypair first, TLS-PSK second.
   The app stores approved client public keys and optional client labels. The CLI
   stores its private key and app fingerprint in the user's Keychain or an
   app-support file protected with normal user permissions. On connect, the app
   sends a nonce in the initialize approval path; the client signs it; the app
   verifies the signature against a paired public key. Once this is stable,
   derive or provision a PSK for `NWProtocolTLS` so the channel itself is
   encrypted and endpoint identity is verified before MCP messages flow.

## PoC Results

No PoC branch was created. The hardest unknown is not whether Network.framework
can configure TLS-PSK; Apple exposes the needed Security protocol option. The
real integration risk is product and migration complexity: how Claude Desktop,
the bundled `imcp-server`, MCP Inspector, and future clients receive and protect
their pairing material without making setup brittle.

## Phased Build Proposal

019 - Add handler-level approval defense. Keep the already-fixed
post-approval registration order and add an actor-owned approved connection set
checked by `ListTools` and `CallTool`. Risk: low; this is a guardrail against
future regressions.

020 - Add paired-client data model and app trust store. Introduce a trusted
client record keyed by public-key fingerprint, not name, with add/remove/reset UI
and migration copy for legacy name entries. Risk: medium; data migration and
Settings copy need careful handling.

021 - Implement CLI pairing bootstrap. Add a pairing mode to `imcp-server` and
update Claude Desktop setup to create or reuse client key material, persist the
app fingerprint, and avoid touching unrelated Claude config. Risk: medium-high;
this touches user setup.

022 - Require signed nonce on MCP initialize. The app issues a nonce, the client
signs it, and unpaired clients fall back to explicit UI approval only for pairing
requests, not normal tool access. Risk: medium; the MCP initialize path must
remain compatible with the Swift SDK.

023 - Add TLS-PSK or pinned local TLS. Replace plain `NWParameters.tcp` with
`NWParameters(tls:tcp:)`, configure the Security protocol options, and make the
CLI verify the paired app fingerprint before proxying stdin/stdout. Risk: high;
transport failures break every client.

024 - Migration and compatibility hardening. Provide clear errors for unpaired
clients, MCP Inspector instructions, key rotation, and a way to reset pairing
from Settings. Risk: medium; this is mostly UX and supportability.

## Open Questions

- Should the paired CLI private key live in Keychain, Application Support, or be
  delegated to each MCP client?
- Is requiring users to re-run setup acceptable, or should there be a temporary
  grace mode that still prompts every unpaired connection?
- Should iMCP keep Bonjour once cryptographic pairing exists, or switch the
  local app-to-CLI hop to XPC for peer code-signing checks?
- What exact external-client story is required for MCP Inspector and non-Claude
  clients before transport encryption ships?

## References

- Apple Developer Documentation: Code Signing Services -
  https://developer.apple.com/documentation/security/code-signing-services
- Apple Developer Forums: validating XPC peer signatures -
  https://developer.apple.com/forums/thread/681053
- Apple Developer Documentation: NWParameters -
  https://developer.apple.com/documentation/network/nwparameters
- Apple Developer Documentation: NWProtocolTLS.Options -
  https://developer.apple.com/documentation/network/nwprotocoltls/options
- Apple Developer Documentation: Security Options -
  https://developer.apple.com/documentation/network/security-options
- Apple Developer Documentation: sec_protocol_options_add_pre_shared_key -
  https://developer.apple.com/documentation/security/sec_protocol_options_add_pre_shared_key%28_%3A_%3A_%3A%29
- Apple Developer Documentation: Creating an Identity for Local Network TLS -
  https://developer.apple.com/documentation/network/creating-an-identity-for-local-network-tls
- Apple Developer Documentation: Keychain Services -
  https://developer.apple.com/documentation/security/keychain-services
- Apple Developer Documentation: Storing Keys in the Keychain -
  https://developer.apple.com/documentation/security/storing-keys-in-the-keychain
- Apple Developer Documentation: App Sandbox -
  https://developer.apple.com/documentation/security/app-sandbox
