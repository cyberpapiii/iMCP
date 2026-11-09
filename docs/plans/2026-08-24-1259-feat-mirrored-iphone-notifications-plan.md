---
title: Mirrored iPhone Notifications - Plan
type: feat
date: 2026-08-24
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# Mirrored iPhone Notifications

## Goal Capsule

**Objective:** `notifications_fetch` returns a trustworthy, read-only view of recent notifications visible on this Mac, including notifications forwarded from an iPhone, with explicit provenance and coverage.

**Means:** Read the confirmed mirrored-notification plist store through a bounded decoder, normalize it beside the existing local SQLite source, and merge both sources behind the existing MCP tool (KTD1, KTD2, KTD3).

**Authority:** Product requirements and session-settled decisions in this plan override implementation convenience. Apple-owned stores remain read-only. Stop if the installed app cannot read the Remote store without a private entitlement, if the live archive schema contradicts the characterized format, if content requires decrypting Apple-owned material with keys unavailable to the installed app, or if a proposed implementation could write notification contents outside memory.

**Execution profile:** Implement and verify in dependency order. The executor owns formatting, tests, build proof, installed-app access proof, real MCP proof, documentation, and removal of abandoned experiments.

---

## Product Contract

### Summary

Extend the existing Notifications service so callers can query both native Mac notifications and notifications forwarded from an iPhone. The response keeps its existing ItemList shape while adding per-item provenance, normalized occurrence time with its evidence kind, and an aggregate account of which requested sources were successfully read.

### Problem Frame

The current service equates Notification Center history with delivered rows in `group.com.apple.usernoted/db2/db`. On the investigated Mac running macOS 26.5.2, forwarded iPhone notifications are instead present in `group.com.apple.UserNotifications/Library/UserNotifications/Remote/default`: `Library.plist` maps app bundle identifiers to source directories, and each source's `DeliveredNotifications.plist` is a readable keyed-archive plist whose graph contains the visible notification strings without a separate decryption step. As a result, visible mirrored notifications are silently absent from current results.

### Requirements

- **R1.** With no `source` argument, `notifications_fetch` requests both local Mac and mirrored iPhone notifications.
- **R2.** Callers can restrict retrieval with `source: all | mac | iphone`; existing date, app, query, and limit inputs apply consistently to the selected sources.
- **R3.** Every result states whether it came from the local Mac store or the mirrored iPhone store without inferring provenance from bundle ID or app name.
- **R4.** Results expose an `occurredAt` wall-clock timestamp and its evidence kind (`delivered` locally, `created` for the archive's `AppNotificationCreationDate`), are merged deterministically newest first by that timestamp, and apply the requested limit after filtering and merging. Existing local `deliveredAt` remains compatible; mirrored records use `createdAt` rather than claiming a proven Mac delivery time. Cross-device clock skew or forwarding delay can affect cross-source rank, so the evidence kind remains visible on every item.
- **R5.** Existing local notification IDs and fields remain compatible. Mirrored IDs are stable within their source and namespaced to avoid collisions.
- **R6.** Each requested source reports `available`, `degraded`, `unavailable`, `denied`, `changedDuringRead`, or `malformed`, plus whether bounded scanning truncated possible matches. `degraded` means the source was readable but at least one requested sub-archive was skipped. Each source also reports `damagedTextRecords`, the number of returned records whose free text was damaged (see R8); such records are present, so they never make a source `degraded` on their own. One successful requested source can produce a partial-success response; failure of every requested source produces a sanitized tool error. An unreadable source is never represented as an empty successful source.
- **R7.** Mirrored retrieval reads only `Library.plist` and mapped `DeliveredNotifications.plist` files, decodes their immutable plist values through explicit bounded UID traversal in memory, and never invokes unrestricted object unarchiving or writes notification contents or copied archives to disk. Initial hard ceilings are 8 MiB per plist, 64 MiB per fetch, 1,024 mapped app directories, 25,000 decoded records, and 64 graph levels; hitting a ceiling marks mirrored coverage truncated or unavailable instead of returning a complete empty result.
- **R8.** Caller values are used only for comparison with already-decoded fields and never to construct paths. Only UUID child names obtained from `Library.plist` may be resolved; every opened directory and regular file is confined beneath the Remote root with no-follow, descriptor-backed validation. Unknown, malformed, oversized, changing, or escaping artifacts fail closed without disclosing private paths or notification contents. A stably absent delivered archive is an empty successful app; a present but unreadable or invalid archive degrades the source. Damaged free text is the one exception to failing closed: when a record's `AppNotificationTitle`, `AppNotificationSubtitle`, or `AppNotificationMessage` is a binary-plist UTF-16 string whose code units are not valid UTF-16 (for example a lone surrogate), and every structural check on the archive passes, the record is returned with that field absent and a `damagedText` entry naming the field (`title`, `subtitle`, or `body`), `error: invalidUTF16`, `encoding: utf-16be`, the code-unit count, and the original bytes as base64. The text is never repaired, replaced with U+FFFD, or guessed, and damaged text cannot match a `query`. Invalid UTF-16 anywhere else (identifiers, dates, dictionary keys, class names, `$archiver`, `Library.plist` mappings) and invalid ASCII still fail closed. The evidence is bounded by the R7 per-file ceiling, since the original string lies inside one delivered archive.
- **R9.** The tool description and user documentation explain merged-by-default behavior, source filtering, provenance, permission needs, untrusted third-party notification text, the lack of heuristic cross-source deduplication, and the fact that mirrored coverage is the Mac's forwarded-notification surface rather than complete iPhone history.

### Key Decisions

- **Use the confirmed on-disk Remote plist store for mirrored notifications.** (session-settled: user-approved — chosen over private Screen Continuity APIs and Accessibility: the store contains the required content and avoids private entitlements) Governs R3, R6, R7, R8.
- **Keep the existing local SQLite source and merge normalized results.** (session-settled: user-approved — chosen over forcing remote semantics into `usernoted`: the two sources have different persistence models) Governs R1, R2, R4, R5.
- **Make coverage and provenance explicit while remaining read-only.** (session-settled: user-approved — chosen over silently presenting local-only results as complete: callers need to distinguish no matches from unavailable coverage) Governs R3, R6, R7, R9.

### Acceptance Examples

- A mirrored notification with an explicitly synthetic unique title is present in a Remote-store fixture but absent from local SQLite. An unfiltered fetch and `source: iphone` both return it with iPhone provenance; `source: mac` does not.
- The local source succeeds while the Remote root is inaccessible. The default fetch returns local results and marks iPhone coverage unavailable; an iPhone-only fetch returns a sanitized error.
- Two different notifications have the same app, title, body, and timestamp. Both remain because no shared native identity proves they are duplicates.
- A query matches an older local item and a newer mirrored item. The response is newest first among records inside each source's scanned window; if a ceiling prevents exhausting possible matches, coverage says the result may be truncated.

### Scope Boundaries

This work includes read-only fetch, normalized provenance, source filtering, deterministic merging, explicit coverage, compatibility tests, permission guidance, and live installed-app/MCP proof. It does not add notification actions, dismissal, clearing, attachments, per-device identity, screenshot scraping, Accessibility automation, private framework calls, or a claim of complete iPhone history. Enabling forwarding and granting macOS privacy access remain user actions.

### Sources

- [Apple: Use iPhone notifications on Mac](https://support.apple.com/en-us/120684)
- [Apple Developer: `getDeliveredNotifications`](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getdeliverednotifications(completionhandler:)) — public API is scoped to the calling app's notifications.
- `App/Services/Notifications.swift` — current local source and MCP contract.
- `docs/solutions/integrations/find-my-people-local-storage.md` — adjacent read-only Apple-store, privacy, consistency, and explicit-source-outcome pattern.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Bounded plist graph decoder.** Decode `Library.plist` and keyed `DeliveredNotifications.plist` archives with `PropertyListSerialization` plus explicit UID traversal. Accept only the characterized classes, keys, scalar types, and collection bounds. Do not use unrestricted object unarchiving. (session-settled: user-approved — chosen over private Screen Continuity APIs and Accessibility: this uses the confirmed readable storage boundary) Covers R3, R7, R8.
- **KTD2. Source adapters and normalized records.** Extract the current local reader behind an internal source interface and add a mirrored reader that emits the same normalized model plus source-qualified identity. Keep decoding details inside each adapter. (session-settled: user-approved — chosen over embedding both storage formats in the tool handler: independent failure and coverage require independent readers) Covers R1-R6.
- **KTD3. Coordinator-owned semantics.** A coordinator parses source selection and owns exact date, app, and query semantics over normalized records. Adapter predicates are conservative pushdown hints only. The coordinator merges bounded candidates on normalized occurrence time with a source-qualified identity tie-break, applies the global limit, and emits item provenance, timestamp evidence, and per-source coverage. (session-settled: user-approved — chosen over source-local limits and silent fallback: global ordering and truthful partial success need one owner) Covers R1-R6.
- **KTD4. No speculative cross-source content deduplication.** Within the mirrored source, identity is bundle identifier plus native notification identifier; local identity remains the existing record ID. Preserve distinct records across sources because identical visible text and nearby timestamps are insufficient evidence of identity. Covers R4, R5.
- **KTD5. Prove access before adding permission machinery.** First test the normally signed installed app against the Remote root. Add a narrowly scoped bookmark/access flow only if that probe demonstrates it is necessary; do not add sandbox temporary exceptions that cannot affect this unsandboxed target. Covers R6-R9.

### High-Level Technical Design

The sketch is directional, not a prescription for exact types or signatures.

```text
MCP arguments
    |
    v
source selection + shared fetch policy
    |-------------------------------|
    v                               v
local SQLite adapter          mirrored plist adapter
usernoted/db2                 Remote/default
    |                               |
    v                               v
normalized notification + categorical source outcome
    |-------------------------------|
                    v
          authoritative filter -> stable sort -> limit
                    |
                    v
       ItemList + provenance + coverage
```

```text
requested source outcome
    available ---------> include records and available coverage
    degraded ----------> include valid records and name partial coverage
    unavailable/denied -> include partial coverage if another source succeeds
    changed/malformed -> include partial coverage if another source succeeds
    all requested fail -> sanitized MCP error
```

### Assumptions

- Omitted `source` means `all`, as requested, even though this broadens the current Mac-only default.
- Public provenance is limited to `mac` and `iphone`; the confirmed store does not justify stable device identity.
- The mirrored root is `~/Library/Group Containers/group.com.apple.UserNotifications/Library/UserNotifications/Remote/default`, and `Library.plist` maps bundle IDs to relative source directories.
- The initial mirrored-read ceilings in R7 are deliberately well above the observed four delivered archives (about 194 KiB total, largest about 160 KiB) while still bounding pathological input. The implementation may lower them only with fixture and live evidence.
- Existing `ItemList` fields remain and normalized time, timestamp evidence, and coverage are additive. Exact coverage field names may follow repository conventions, provided tests lock the semantics and category meanings in R4 and R6.
- If metadata changes during a mirrored snapshot, one bounded retry is acceptable; repeated change becomes `changedDuringRead` rather than returning an untrustworthy snapshot.

### System-Wide Impact

The MCP schema gains one optional enum and additive response fields, service activation changes from one mandatory store to at least one readable source, and user-facing permission guidance must cover both stores. Logging must remain metadata-only because notification bodies and absolute paths are sensitive. The reader is tied to an undocumented Apple archive and therefore needs strict failure categories instead of schema guesses.

### Risks and Dependencies

- Apple may change the Remote plist schema or location. Strict characterization fixtures and live proof guard against silent mis-decoding, but compatibility remains version-sensitive.
- Full Disk Access and the installed signature determine live readability. Unit tests cannot prove that privacy boundary.
- Notification Center can selectively suppress forwarding by app or availability state. An available archive proves only what reached this Mac.
- A malformed archive for one app must not poison unrelated mirrored apps; aggregate mirrored coverage must say when any requested portion was skipped.

### Sequencing

Before U1 implementation, reuse the repository's stable-signing install flow for a metadata-only probe that confirms the installed app can read the Remote root without a private entitlement. U1 then establishes the safe model and decoder. U2 extracts the local adapter without changing local behavior. U3 adds the mirrored adapter and adds narrowly scoped access machinery only if the preflight proved it necessary. U4 integrates tool semantics and documentation. U5 repeats the access probe as part of end-to-end proof. Characterization or access evidence that invalidates KTD1 or KTD5 stops implementation for replanning.

---

## Implementation Units

### U1. Define normalized records, source outcomes, and bounded archive decoding

**Goal:** Establish testable internal contracts and safely decode sanitized Remote-store fixtures.

**Requirements:** R3, R5-R8; KTD1, KTD2, KTD4.

**Files:** `App/Services/Notifications.swift`; new focused source/decoder file under `App/Services/`; `iMCPTests/NotificationsServiceTests.swift` and sanitized test fixtures if needed.

**Approach:** Begin with the signed-app metadata-only access preflight. Then introduce normalized identity, provenance, occurrence time with evidence kind, and stable source outcome categories. Implement explicit `Library.plist` mapping and keyed-archive graph traversal with descriptor-relative no-follow opens, UUID child validation, regular-file/directory checks, identity and metadata checks before and after the bounded read, and no content logging.

**Execution note:** Characterize first from synthetic fixtures shaped like the confirmed live archives; fail closed on any unrecognized required structure.

**Test Scenarios:** Decode a valid library plus delivered archive with title, subtitle, body, creation date, bundle ID, and native identifier. Reject traversal/symlink mappings, caller-shaped paths, cyclic or out-of-range UIDs, unexpected root types, oversized per-file and aggregate inputs, excessive directories/records/depth, and malformed archives. Detect replacement or mutation of an opened file. Preserve two content-identical records with different native IDs.

**Verification:** Focused `NotificationsServiceTests` pass with fixtures containing no real user data or absolute paths.

### U2. Extract and preserve the local Mac notification source

**Goal:** Put the existing SQLite behavior behind the normalized source boundary without regressing its public output.

**Requirements:** R3-R6; KTD2, KTD3.

**Files:** `App/Services/Notifications.swift`; the source contract file from U1; `iMCPTests/NotificationsServiceTests.swift`.

**Approach:** Move SQLite open/query/decode into a local adapter that emits normalized records and an available or sanitized failed outcome. Preserve existing local IDs, `deliveredAt`, timestamp conversion, bundle filtering, security-scoped lifetime, and bounded search behavior while marking local occurrence time as delivered evidence.

**Test Scenarios:** A synthetic local database yields the same ID/date/app/content as before. Date/app filters and malformed content retain current behavior. Open/query failures return categorical outcomes without raw paths or SQLite details. A zero-row successful query is distinguishable from failure.

**Verification:** Existing tests plus a real SQLite fixture pass; a Mac-only tool response remains compatible apart from additive provenance, normalized occurrence time with evidence kind, and coverage fields.

### U3. Read mirrored iPhone notifications as an independent source

**Goal:** Retrieve current forwarded notifications from the confirmed Remote plist store with explicit iPhone provenance.

**Requirements:** R3-R8; KTD1, KTD2, KTD4, KTD5.

**Files:** the mirrored source/decoder file from U1; `App/Services/Notifications.swift`; `iMCPTests/NotificationsServiceTests.swift`; permission/access code only if the installed-app probe requires it.

**Approach:** Snapshot `Library.plist`, resolve only mapped UUID child directories beneath the root, and read only `DeliveredNotifications.plist`. Normalize characterized `AppNotification*` fields, expose archive creation time as `createdAt` plus normalized `occurredAt`, and define mirrored identity as bundle identifier plus native notification identifier. Records missing either identity component fail closed and degrade coverage. Isolate per-app failures and avoid the attachment tree entirely.

**Test Scenarios:** Read multiple apps and globally order their records. Support missing optional title/subtitle/body. Apply date and app filtering. Treat a stably missing app archive as empty success; treat a present unreadable archive, one malformed app archive, or repeated metadata change as degraded coverage while returning other apps. Reject missing/repeated identity components, prove paths cannot escape the root, and ensure no fixture payload reaches logs.

**Verification:** Fixture tests pass and a signed installed build can enumerate mirrored metadata on the test Mac without private frameworks or Accessibility.

### U4. Merge sources through the MCP contract and document behavior

**Goal:** Make merged, filterable, provenance-aware notifications available through `notifications_fetch` with truthful coverage.

**Requirements:** R1-R9; KTD2-KTD5.

**Files:** `App/Services/Notifications.swift`; source files; `iMCPTests/NotificationsServiceTests.swift`; `README.md`; `App/Controllers/ServiceRegistry.swift` if permission text needs adjustment.

**Approach:** Add the source enum to the input schema and default to both adapters. The coordinator owns exact date-boundary, bundle-identifier, and query semantics; adapter predicates are pushdown hints that must not narrow beyond those rules. Each adapter returns at least the effective limit's worth of newest post-filter candidates unless it hits a documented ceiling, in which case coverage is truncated. Merge deterministically on `occurredAt` with the source-qualified identity as tie-break, then apply the global limit. Preserve the ItemList and local fields, add provenance and timestamp evidence per item, and add stable per-source coverage. Activate when at least one source is readable; error only when every requested source fails.

**Test Scenarios:** Exercise all/mac/iphone selection, omitted-source default, identical date boundaries and exact bundle matching across sources, query filtering, equal timestamps, the candidate-window boundary, global limit, mirrored-only and local-only success, one-source partial success, degraded mirrored success, all-source failure, complete empty results, and duplicate-looking records. Reject invalid source values through schema/input handling.

**Verification:** Focused tests assert the public Value shape and descriptions; README examples match the schema and caveats.

### U5. Prove the installed and agent-facing path

**Goal:** Demonstrate that the feature works outside fixtures through the same signed app and MCP path users run.

**Requirements:** R1-R9; KTD5.

**Files:** `Scripts/install-local.sh` only if an existing verification mode needs a narrow extension; otherwise no production file.

**Approach:** Format and run focused/full tests, build the app, install it with the repository's stable-signing flow, then call the real MCP tool against a currently visible mirrored notification and a local notification. Inspect only identifiers/counts needed for proof; do not capture bodies in logs or committed artifacts. Compare relevant source-file metadata before and after reads. Treat the live observation as one-time parity proof; repeatable behavior stays fixture-backed.

**Test Scenarios:** The real call returns one known mirrored record with iPhone provenance and one local record with Mac provenance. Source filtering isolates each. Read-only metadata checks show no content-store mutations attributable to iMCP. Deliberate unavailability remains fixture/injected-adapter proof; do not manipulate Apple-owned files, permissions, or privacy state for a live failure drill.

**Verification:** `swift format lint --strict --recursive .`; focused app tests; `xcodebuild test -scheme iMCP -destination "platform=macOS"`; `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"`; Debug build; signing verification; installed-app access probe; real MCP fetch.

---

## Verification Contract

Run formatting before final tests because CI enforces it:

```console
swift format -i -r .
swift format lint --strict --recursive .
xcodebuild test -scheme iMCP -destination "platform=macOS"
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build
Scripts/install-local.sh verify
```

Unit proof must cover bounded decoding, descriptor-backed path confinement, normalized source behavior, source selection, filtering, stable ordering, global limiting, response compatibility, degraded and partial coverage, and all-source failure. Integration proof must use the normally signed installed app and one real MCP call that returns both a mirrored and a local record; source inspection or green fixtures alone are insufficient. Verification output and diagnostics must not contain notification bodies, absolute user paths, keys, or copied live archives.

---

## Definition of Done

- U1-U5 verification is complete and all R1-R9 behaviors are demonstrated.
- `notifications_fetch` returns local and mirrored records by default, supports source selection, preserves local compatibility, and reports provenance and coverage.
- The implementation uses no private framework, private entitlement, Accessibility scraping, attachment crawl, or persistent copy of notification content.
- Unit, app, CLI, formatting, build, signing, installed-app access, and real MCP checks pass at the final commit.
- Documentation states the permission and completeness boundaries accurately.
- The final diff contains no real notification data, absolute user paths, debug instrumentation, dead-end experiments, or unrelated `.hermes` artifacts.
