# Plan 035: Correct the install path, document local signing, refresh agent docs

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 17d7c72..HEAD -- README.md CLAUDE.md AGENTS.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live files before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW — documentation only, no code changes
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `17d7c72`, 2026-08-07

## Why this matters

Three documentation defects, all of which actively mislead rather than merely
omit:

1. **The README's Getting Started installs a different app than the one it
   documents.** Both the download link and the Homebrew cask distribute
   `mattt/iMCP` (upstream). This fork is **67 commits ahead and 0 behind**
   (`git rev-list --left-right --count origin/main...main` → `0 67`). Everything
   the same README describes in its Security and Pairing sections —
   `imcp-server --pair`, `--fingerprint`, `--rotate-key`, the "Always allow this
   client (pair)" checkbox, Unpair All Clients, the Permissions settings tab —
   exists **only in this fork**. A reader who follows the install instructions
   and then runs `imcp-server --pair` gets an unrecognized-flag error.
2. **The local-development signing requirement is undocumented.** The README
   tells contributors to build the `iMCP` scheme in Xcode — precisely the path
   that produces an unstable development signature, which breaks Full Disk
   Access and Location grants on every rebuild and makes the Keychain-stored
   client key unreachable. The two scripts that fix this (`Scripts/install-local.sh`,
   `Scripts/verify-app-signing.sh`) appear in no documentation at all; the
   reason lives only in a code comment.
3. **`CLAUDE.md`'s Key Paths no longer describe the codebase.** It points agents
   at `ServerController.swift` for the network listener and MCP server core —
   but plan 013 moved those to `ServerNetworkManager.swift`. There is no entry
   at all for `App/Shared/`, which now holds the entire pairing/auth subsystem,
   the most security-sensitive code in the project. Agents executing plans in
   this directory are being pointed at the wrong files.

## Current state

### README install section

```markdown
<!-- README.md:112-122 -->
## Getting Started

### Download and open the app

First, [download the iMCP app](https://iMCP.app/download)
(requires macOS 15.3 or later).

Or, if you have [Homebrew](https://brew.sh) installed,
you can run the following command:

```console
brew install --cask mattt/tap/iMCP
```
```

The MCP client snippets at `README.md:252`, `:270`, and `:283` all reference
`/Applications/iMCP.app`, which those commands populate with the upstream build.

### README build-from-source section

```markdown
<!-- README.md:384-397 -->
### Building from source

Source builds use Xcode 26 on macOS 26 in CI.
Open `iMCP.xcodeproj` in Xcode and build or run the `iMCP` scheme.
Debug builds do not require a provisioning profile.

From Terminal, use the same commands CI uses:

```console
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"
xcodebuild test -scheme iMCP -destination "platform=macOS"
swift format lint --strict --recursive .
```
```

### The undocumented scripts

- `Scripts/install-local.sh` — builds, re-signs with a stable local identity,
  and installs to `/Applications`. Its signing identity defaults to
  `Plug Local Signing` (`Scripts/install-local.sh:8`,
  `IMCP_SIGN_IDENTITY:-Plug Local Signing`). The reason is in a code comment at
  `:47-48`: it replaces "the unstable development signature with the stable
  local identity macOS uses for TCC and Keychain".
- `Scripts/verify-app-signing.sh` — asserts the installed bundle's signature and
  entitlements.
- `script/build_and_run.sh` — dev convenience wrapper. **Note the lowercase
  `script/` directory**, separate from `Scripts/`.
- `Scripts/release.sh` — release automation; the only script currently
  mentioned in `CLAUDE.md`.

Read each script's usage/help block before documenting it, so the flags you
document are the flags it actually accepts. Do **not** run them.

### `CLAUDE.md` Key Paths, as it stands

```markdown
<!-- CLAUDE.md:38-49 -->
## Key Paths

- `App/Services/` - one file per MCP service.
- `App/Controllers/ServerController.swift` - network listener, MCP server core,
  service enablement, and connection approval.
- `CLI/main.swift` - stdio to Bonjour proxy used by MCP clients.
- `App/Models/` - shared service, tool, and value models.
- `Scripts/release.sh` - release automation.
- `plans/` - improvement plans; read the relevant plan fully before
  implementing it.
```

What is actually true now, verified by reading the files:

- `App/Controllers/ServerNetworkManager.swift` (709 lines) — the network
  listener, MCP server core, per-connection handlers, auth-preamble
  verification, and tool gating.
- `App/Controllers/ServerController.swift` (358 lines) — connection-approval
  queueing and `@AppStorage` service enablement.
- `App/Shared/` — the pairing/auth subsystem: `AuthPreamble.swift` (309 lines),
  `PairingCodeIssuer.swift`, `ConnectionApprovalPairing.swift`,
  `ListenerEndpointFile.swift`, `ResumeGate.swift`. Files here are compiled into
  **both** the app and the CLI targets.
- `CLI/` — `main.swift` (822 lines) plus `BonjourEndpointSelection.swift`,
  `CLIBootstrap.swift`, `ClientKeyStore.swift`, `MessageFrameScanner.swift`.
- The CLI no longer discovers the app by Bonjour alone: the app writes its
  listener port to `~/Library/Application Support/iMCP/listener-endpoint.json`
  and the CLI prefers a direct `127.0.0.1` connection, with Bonjour as the
  fallback (`App/Shared/ListenerEndpointFile.swift:1-12`, consumed at
  `CLI/main.swift:639-653`). This exists because macOS gates Bonjour resolution
  behind the Local Network privacy permission, which background daemons never
  get prompted for.

`AGENTS.md` exists at the repo root — read it and check whether it duplicates
`CLAUDE.md`'s Key Paths. If it does, it needs the same corrections.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Lint | `swift format lint --strict --recursive .` | exit 0 |
| Build (sanity) | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |

`swift format` does not process Markdown, but run the lint gate anyway to
confirm you did not accidentally modify a Swift file.

## Scope

**In scope** (the only files you should modify):
- `README.md`
- `CLAUDE.md`
- `AGENTS.md` (only if it carries the same stale Key Paths)

**Out of scope** (do NOT touch, even though they look related):
- Any file under `App/`, `CLI/`, `Scripts/`, or `script/`. This is a
  documentation-only plan. In particular, do **not** consolidate the
  `Scripts/` and `script/` directories — that is a real finding but it breaks
  paths that documentation and muscle memory depend on, and it needs its own
  plan.
- Publishing releases for this fork, changing the Homebrew cask, or editing
  `Scripts/release.sh`. Step 1 adds a **warning**, not a release channel.
- `plans/` files other than the status row for this plan.
- Running any script in `Scripts/` or `script/`. Read them; do not execute them.

## Git workflow

- Branch: `advisor/035-docs-truth-pass`
- Conventional commits, e.g.
  `docs: warn that published builds are upstream, not this fork`.
- Do NOT push or open a PR unless the operator asks.

## Steps

### Step 1: Warn that the published builds are upstream

At the top of the "Getting Started" section in `README.md` (immediately after
the `## Getting Started` heading, before "Download and open the app"), add a
short, clearly-formatted note stating that:

- the download link and Homebrew cask distribute the upstream `mattt/iMCP`
  build;
- this fork is substantially ahead, and the pairing, permissions, and
  local-signing features documented later in this README are **not** in the
  upstream build;
- to get those features, build from source — link to the "Building from source"
  section.

Keep it to three or four sentences. Do not remove the existing links; a reader
who wants the upstream build should still be able to get it.

**Verify**:
```console
grep -c "upstream" README.md    # expect >= 1
```
→ `≥ 1`.

### Step 2: Document the local-development install

Extend the "Building from source" section of `README.md` with a
"Local development install" subsection covering:

- **Why it is needed**: an Xcode development signature is unstable across
  rebuilds, and macOS ties TCC grants (Full Disk Access, Location, Screen
  Recording) and Keychain access to the signing identity — so a plain rebuild
  silently breaks previously-granted permissions and makes the stored client key
  unreachable. Two sentences.
- **How to fix it**: `Scripts/install-local.sh` re-signs with a stable local
  identity and installs to `/Applications`; `Scripts/verify-app-signing.sh`
  checks the result.
- **The identity**: the default is `Plug Local Signing`, overridable via the
  `IMCP_SIGN_IDENTITY` environment variable, and it must be a self-signed
  codesigning identity in the user's keychain. Say briefly how to create one
  (Keychain Access → Certificate Assistant → Create a Certificate, type "Code
  Signing", self-signed).
- **The dev wrapper**: `script/build_and_run.sh` and its flags — read the script
  first and document the flags it actually supports.
- **A caution**: re-signing is required after *every* reinstall, or the FDA and
  Location grants break again.

**Verify**:
```console
grep -c "install-local.sh" README.md          # expect >= 1
grep -c "IMCP_SIGN_IDENTITY" README.md        # expect >= 1
grep -c "build_and_run.sh" README.md          # expect >= 1
```
→ each `≥ 1`.

### Step 3: Correct `CLAUDE.md` Key Paths and architecture summary

Rewrite the Key Paths list in `CLAUDE.md` to match the facts inventoried in
"Current state":

- `App/Controllers/ServerNetworkManager.swift` — listener, MCP server core, auth
  preamble verification, tool gating.
- `App/Controllers/ServerController.swift` — connection approval queue and
  service enablement.
- `App/Shared/` — pairing/auth primitives shared by **both** the app and CLI
  targets; name `AuthPreamble.swift` and `ListenerEndpointFile.swift`
  specifically.
- `CLI/` — name `main.swift` plus the four extracted files.
- `Scripts/` — `release.sh`, `install-local.sh`, `verify-app-signing.sh`; and
  `script/build_and_run.sh` (noting the separate lowercase directory, so nobody
  loses time to the ambiguity).
- Keep the existing `App/Services/`, `App/Models/`, and `plans/` entries.

Then extend the intro paragraph at the top of `CLAUDE.md` with one sentence on
the loopback fast path: the CLI prefers a direct `127.0.0.1` connection using
the port the app publishes to `listener-endpoint.json`, falling back to Bonjour
discovery — because macOS gates Bonjour resolution behind the Local Network
privacy permission.

If `AGENTS.md` duplicates any of this, apply the same corrections there.

**Verify**:
```console
grep -c "ServerNetworkManager.swift" CLAUDE.md    # expect >= 1
grep -c "App/Shared/" CLAUDE.md                   # expect >= 1
grep -c "install-local.sh" CLAUDE.md              # expect >= 1
grep -c "loopback" CLAUDE.md                      # expect >= 1
```
→ each `≥ 1`.

### Step 4: Fix the stale protocol reference link

`README.md:376` links to a pinned upstream commit
(`github.com/mattt/iMCP/blob/8cf9d250.../CLI/main.swift#L47`) as the reference
for the app↔CLI protocol. That revision predates both the auth preamble and the
loopback fast path — the two things most likely to confuse someone debugging a
connection failure. Point the link at this repository's `CLI/main.swift`
instead, and add one sentence to the surrounding prose noting the loopback
endpoint file and the Bonjour fallback.

**Verify**: `grep -c "8cf9d250" README.md` → `0`.

### Step 5: Run the sanity gate

```console
swift format lint --strict --recursive . ; echo "exit=$?"
git status --porcelain
```

**Verify**: `exit=0`, and `git status` lists only `README.md`, `CLAUDE.md`,
optionally `AGENTS.md`, and `plans/README.md`.

## Test plan

No automated tests — this plan changes documentation only. Verification is the
`grep` assertions in each step plus a human read-through for accuracy.

**Accuracy check before you finish**: every command, flag, and path you wrote
must be one you verified by reading the corresponding file. Do not document a
flag you inferred. If a script's behavior is unclear from reading it, document
less rather than guessing — an inaccurate doc is worse than a missing one, which
is the whole premise of this plan.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "upstream" README.md` → `≥ 1`
- [ ] `grep -c "install-local.sh" README.md` → `≥ 1`
- [ ] `grep -c "IMCP_SIGN_IDENTITY" README.md` → `≥ 1`
- [ ] `grep -c "build_and_run.sh" README.md` → `≥ 1`
- [ ] `grep -c "8cf9d250" README.md` → `0`
- [ ] `grep -c "ServerNetworkManager.swift" CLAUDE.md` → `≥ 1`
- [ ] `grep -c "App/Shared/" CLAUDE.md` → `≥ 1`
- [ ] `grep -c "loopback" CLAUDE.md` → `≥ 1`
- [ ] `grep -c "ServerController.swift.*network listener" CLAUDE.md` → `0` (the stale claim is gone)
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `git status --porcelain` lists only the in-scope files
- [ ] `plans/README.md` status row for 035 updated

## STOP conditions

Stop and report back (do not improvise) if:

- A script's actual flags or behavior contradict what this plan describes —
  document what the script really does and flag the discrepancy in your report.
- `AGENTS.md` turns out to be substantially different in purpose from
  `CLAUDE.md` (not a duplicate), such that editing it is a judgment call rather
  than mechanical.
- You find that this fork **does** publish its own releases somewhere, which
  would make the Step 1 warning wrong. Check `Scripts/release.sh` and the git
  tags before writing the warning.
- Documenting the signing identity would require naming a certificate that does
  not exist on a fresh machine without explaining how to create it.

## Maintenance notes

For the human/agent who owns this after the change lands:

- **The Step 1 warning is a stopgap.** The real fix is publishing releases for
  this fork and repointing the download link and cask. That is a bigger decision
  (release channel, notarization, cask maintenance) and it interacts with a
  known bug: `Scripts/release.sh:410` and `:426` call `gh release create` /
  `gh release upload` with **no** `-R` flag, while `origin` points at the
  read-only upstream and `personal` points at the fork. Running the release
  pipeline as-is would resolve the target repo ambiguously — and would do so
  only *after* the expensive archive/notarize/staple steps, with a version-bump
  commit and tag already created locally. Fix that before the first release.
- **A reviewer should check** that every documented flag matches the scripts,
  and that the Key Paths entries match the actual file responsibilities — the
  failure mode being fixed here is documentation drifting from code, so a
  careless fix recreates the problem.
- **Verified accurate, no action needed**: the README capabilities table matches
  the 16 registered services and their ~40 tools. It was checked during the
  audit that produced this plan and does not need re-auditing.
- **Related known gap, not fixed here**: `WEATHERKIT_AVAILABLE` is set only in
  the app target's Release configuration, so a source build following the README
  produces 15 services, not 16 — a developer may reasonably conclude Weather is
  broken. One sentence in Building-from-source would cover it; the underlying CI
  gap is recorded in `plans/029-verification-baseline.md`.
