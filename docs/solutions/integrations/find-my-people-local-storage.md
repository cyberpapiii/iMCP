---
title: Read Find My People from encrypted LocalStorage without plaintext staging
date: 2026-08-24
category: integrations
module: location-find-my-people
problem_type: integration
component: local-storage-bootstrap
severity: high
applies_when:
  - Reading Find My People on macOS 26
  - Handling encrypted LocalStorage.db and WAL state
  - Reviewing one-time key capture or restored-security claims
tags:
  - find-my
  - localstorage
  - wal
  - keychain
  - sip
  - privacy
---

# Read Find My People from encrypted LocalStorage without plaintext staging

## Problem

Find My's People data is not available through iMCP's existing web-device route. The local `findmylocateagent`
`LocalStorage.db` contains the active sharing list, but its SQLite pages are encrypted and the newest committed fix can
exist only in the WAL. Opening Apple's files with SQLite risks checkpointing them, while decrypting to a temporary file
leaks highly sensitive data.

The database key is supplied to SQLCipher's `sqlite3_key_v2` inside Apple's process. Capturing it requires a temporary,
user-directed weakened-security window, but normal operation must not.

## Solution

Keep the concerns separate:

1. The runtime provider opens the main database and WAL read-only, fingerprints them before and after a bounded read,
   validates WAL salts, checksums, page bounds, and the last commit, reconstructs pages in memory, and queries only with
   `sqlite3_deserialize` plus memory-only temporary storage.
2. The app stores the database key and friend-identity secret as separate non-synchronizing, this-device-only Keychain
   items. The default-off People gate remains independent of key presence.
3. Bootstrap uses a one-time non-extractable RSA Keychain private key. LLDB sees only its public handoff; the callback
   accepts only the canonical agent, `sqlite3_key_v2`, the main `LocalStorage.db`, and exactly 32 key bytes. It sends a
   fixed binary payload directly to RSA-OAEP and writes only ciphertext.
4. Import binds the ciphertext to the prepared nonce, safe-baseline digest, installation secret, current boot, and
   device-owner authentication. It validates the key against the live schema before replacing an existing valid key and
   consumes the handoff exactly once.
5. Operational observation polls only labeled path classes, sizes, mtimes, and aggregate process-log event counts. It
   never renders records or log messages.

## Important limitation

The shell verifier cannot create a cryptographically authoritative independent boot-policy receipt with available native
APIs. `bputil` needs an explicit administrator invocation, and the unprivileged app cannot ask a hardware root of trust to
sign the combined Full Security, SIP, authenticated-root, and boot-argument facts. The report is therefore explicitly
`authoritative: false`; the app accepts it only through a fresh device-owner-authenticated manual import gate and its own
binding checks. Never label that report an independent signed attestation.

## Verification

- Frozen codec/WAL known-answer vectors and synthetic SQLite images cover key, schema, WAL-only freshness, and size
  failures without real payloads.
- Bootstrap payload tests cover wrong length, tampering, replay/cross-installation binding, reboot, posture equality, and
  the authenticated manual gate.
- `bash -n`, Python compilation, LLDB batch command registration, and every script's dry-run run without attachment,
  privilege escalation, policy changes, or secret output.
- Privacy scans reject key-like output, coordinates, identity fields, SQL, and absolute user paths in observer output.
- The user-run matrix in `docs/find-my-people-setup.md` is the only native-parity and restored-security proof.

## Sources

- FindMySyncPlus commit `0b8a5fbbeb96dc90313a09a946df22c0a67190bd` for the MIT page codec and WAL prior art.
- findmy-key-extractor commit `3797fbb99e033a474b5c3ef54a60601cc24ee7b1` for the MIT `sqlite3_key_v2`
  capture prior art.

