---
title: Preserve Debug iCloud sessions across cleanup and sign-out
date: 2026-08-28
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---

# Preserve Debug iCloud sessions across cleanup and sign-out

> **Superseded in part (noted 2026-10-12).** Kept as written. "Passwords are
> never persisted" (Goal Capsule, R4, and the verification list) no longer
> holds: by owner decision the Apple ID password is always stored in the
> this-device-only data-protection Keychain item alongside the session
> tokens, with no opt-in. The rest of this plan stands.

## Goal Capsule

Make locally installed Debug builds keep iCloud sessions in the Keychain, preserve explicit sign-out, and report migration persistence failures. Keep passwords out of persistence. Preserve the existing release behavior and injected storage test seam.

## Product Contract

### Problem

Commit `e53a0b8` moved Debug iCloud credentials from the login Keychain to `~/Library/Application Support/iMCP/icloud-credentials.json` to avoid code-signature prompts. Cleanup can delete that file. Legacy Keychain credentials remain after migration, so explicit sign-out can be undone on next launch. Migration also ignores file-write failure.

### Requirements

- R1. Current iCloud credentials remain available after Application Support cleanup and restart.
- R2. Explicit sign-out remains signed out after restart, including when legacy Keychain credentials existed.
- R3. Migration persistence failure surfaces as unavailable storage; it must not appear successful for one launch.
- R4. Session tokens, trust tokens, and cookies remain in this-device-only Keychain storage. Passwords are never persisted.
- R5. Release behavior and existing injected test seams remain source-compatible.
- R6. Tests must not read, overwrite, or delete the user's real Keychain or Application Support credentials.

### Acceptance Evidence

- AE1. A stored current session restores after simulated Application Support deletion and restart.
- AE2. A legacy session migrates, signs out, restarts, and remains signed out.
- AE3. A failed migration write returns unavailable storage and does not report a restored session.
- AE4. Existing iCloud auth flow and storage tests pass.
- AE5. Swift formatting, build, CLI tests, and app tests pass.

## Key Technical Decisions

- KTD1. Use a new, dedicated login-Keychain service as the canonical Debug credential backend and retain the existing service for Release. Keep `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Provenance: live signed-build proof. Rejected: Application Support as canonical storage, the old Keychain service as canonical Debug state, and Data Protection Keychain without an application-identifier entitlement. Reason: cleanup deletes the file; the old item can retain stale ACL state; live Debug execution returned `errSecMissingEntitlement` for Data Protection Keychain. Governs R1, R4, R5.
- KTD2. Keep the Debug file and old Keychain item only as one-time import sources. When canonical state is missing, prefer a valid Debug file because every Debug refresh since `e53a0b8` updated only that file; consult the old Keychain item only when the file is absent or malformed, avoiding its known rebuild prompt on the normal migration path. Save the chosen source to the dedicated Debug Keychain service, verify exact read-back, then delete both import sources. If canonical save or read-back fails, return unavailable and preserve both sources. If source cleanup fails after verified canonical persistence, keep the canonical session authoritative, return it, and retry cleanup on later loads without allowing either source to overwrite canonical state. Provenance: user-approved through LFG invocation on the review. Rejected: old-Keychain-first shadowing, reading a stale old item when a valid file exists, and dual live stores. Reason: the file is authoritative for post-`e53a0b8` Debug sessions and the old item may prompt after rebuilds. Governs R1, R2, R3.
- KTD3. Sign-out deletes import sources before canonical Keychain state. Any import-source deletion failure aborts before canonical deletion and reports failure, leaving the in-memory session unchanged. Canonical deletion happens only after both import sources are absent; all-absent remains idempotent. Provenance: user-approved through the accepted review finding. Rejected: clearing only the selected backend or deleting canonical state first. Reason: a surviving import source can otherwise restore credentials. Governs R2.
- KTD4. Add injected migration seams instead of touching production storage in tests. Provenance: user-approved through the accepted review finding. Rejected: tests against the real login Keychain or user Application Support. Reason: tests must be deterministic and non-destructive. Governs R3, R6.
- KTD5. Credential diagnostics may contain only storage source, OSStatus, and success/failure state. They never include encoded credential data, tokens, cookies, account names, or absolute paths. Provenance: user-approved through security review. Rejected: payload logging for migration debugging. Reason: every persisted field can authorize or identify an iCloud session. Governs R4.

## Existing Patterns

- `App/Services/Location/ICloudCredentialStorage.swift` already implements three-state Keychain loads, update-then-add writes, this-device-only accessibility, and injected raw operations.
- `App/Controllers/PairedClientStorage.swift` shows guarded one-time migration behavior.
- `iMCPTests/ICloudAuthPlumbingTests.swift` owns storage contract tests.
- `iMCPTests/ICloudAuthFlowTests.swift` owns restore, sign-out, and launch behavior.
- `docs/plans/2026-08-23-1559-location-find-my-rebuild-plan.md` requires iCloud session tokens in the Keychain.

## Implementation Units

### U1. Canonical Keychain storage and safe Debug migration

**Covers:** R1, R3, R4, R5, R6; AE1, AE3, AE4.

**Files:**
- `App/Services/Location/ICloudCredentialStorage.swift`
- `App/Shared/SecretFileStore.swift`
- `iMCPTests/ICloudAuthPlumbingTests.swift`

**Work:**
- Make Debug iCloud credential saves canonical in a dedicated Keychain service; keep Release on its existing Keychain path.
- Prefer a valid Debug file when canonical state is absent; fall back to the classic Keychain only when the file is absent or malformed.
- Persist imported data and verify exact canonical read-back before deleting either source.
- Treat failed canonical persistence or read-back as unavailable while preserving sources. After verified canonical persistence, keep canonical state authoritative even when source cleanup must retry.
- Keep all production filesystem and Keychain operations injectable for tests.

**Tests:**
1. Current canonical credentials load without consulting or accepting either import source.
2. Missing canonical state plus valid Debug file migrates, verifies read-back, removes both import sources, and returns credentials.
3. Both import sources present selects the valid Debug file without reading the classic item; absent or malformed file falls back to valid classic credentials.
4. Failed canonical save or mismatched read-back returns unavailable and preserves both sources.
5. Failed source cleanup after verified canonical persistence returns canonical credentials, never reimports stale data, and retries cleanup on recreated storage.
6. Malformed file beside valid classic credentials selects the classic item; malformed sources never overwrite valid canonical state.
7. Recreated storage after simulated Application Support cleanup restores the exact latest canonical credentials.
8. Captured diagnostics contain no account name, token, cookie, encoded credential data, or absolute path.

### U2. Irreversible sign-out across legacy state

**Covers:** R2, R5, R6; AE2, AE4.

**Depends on:** U1.

**Files:**
- `App/Services/Location/ICloudCredentialStorage.swift`
- `App/Services/Location/ICloudAuthClient.swift`
- `iMCPTests/ICloudAuthPlumbingTests.swift`
- `iMCPTests/ICloudAuthFlowTests.swift`

**Work:**
- Clear legacy Debug file and classic Keychain import item before canonical Keychain credentials during explicit sign-out.
- Abort and report partial clear failure before canonical deletion; do not reset in-memory auth state.
- Keep sign-out idempotent when both stores are absent.

**Tests:**
1. Legacy file plus Keychain item, sign-out, restart: storage remains missing.
2. Legacy-file delete fails: sign-out reports failure, canonical state remains, and restart restores the same signed-in session rather than stale import data.
3. Classic-item delete fails: sign-out reports failure and canonical state remains.
4. Both import sources delete, canonical delete fails: sign-out reports failure and canonical state remains readable.
5. All stores absent: sign-out succeeds.
6. Existing sign-out failure contract remains intact.

### U3. Verification and documentation reconciliation

**Covers:** R4, R5; AE4, AE5.

**Depends on:** U1, U2.

**Files:**
- `App/Services/Location/ICloudCredentialStorage.swift`
- `App/Shared/SecretFileStore.swift`
- `docs/solutions/` only if implementation reveals a reusable migration rule.

**Work:**
- Remove comments claiming Debug iCloud credentials intentionally live in Application Support.
- Keep comments accurate for any remaining non-iCloud `SecretFileStore` users.
- Format and verify all affected targets.

## Verification Contract

1. `swift format -i -r .`
2. `swift format lint --strict --recursive .`
3. `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build`
4. `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"`
5. `xcodebuild test -scheme iMCP -destination "platform=macOS"`
6. Recreate the injected production-storage facade to prove simulated cleanup/restart behavior without touching user state.
7. Run `Scripts/install-local.sh verify` to confirm installed Debug signing and entitlements. Installed-app Keychain restore after a future rebuild remains a manual acceptance gate if it would require a Keychain prompt; unit coverage must not claim that GUI proof.
8. Review the final diff for accidental changes to unrelated `.hermes/` state.

## Risks and Stop Conditions

- Stop if the dedicated Debug Keychain service fails under the signed Debug build. Report observed signing identity and status rather than returning to cleanup-prone plaintext credentials.
- Stop if migration would delete the only readable copy before verified canonical persistence.
- Stop if tests require real user credentials or destructive access to the login Keychain.
- Keychain-backed auth changes remain green-but-unverifiable until the installed Debug app restores a real session without prompting; unit tests prove logic, not macOS ACL behavior.

## Definition of Done

- R1-R6 and AE1-AE5 are satisfied by automated logic/build tests; installed-app cross-rebuild ACL behavior is explicitly recorded as a manual acceptance item when GUI proof is unavailable.
- Explicit sign-out cannot remigrate stale credentials.
- Application Support cleanup cannot erase the canonical iCloud session.
- Migration failures are surfaced and preserve the last readable copy.
- No password is persisted or printed.
- Changes are formatted, built, tested, reviewed, committed, pushed, and attached to an open PR.
