# Plan 031: Restrict the listener endpoint handoff file to its owner

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 17d7c72..HEAD -- App/Shared/ListenerEndpointFile.swift iMCPTests/ListenerEndpointFileTests.swift CLI/main.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW-MED (the CLI must still find the app after the change — a mistake here breaks all MCP connectivity via the loopback path, falling back to Bonjour)
- **Depends on**: plans/029-verification-baseline.md
- **Category**: security
- **Planned at**: commit `17d7c72`, 2026-08-07

## Why this matters

The app publishes its listener port to a file that the CLI reads to make a
direct loopback connection. That file is currently **world-readable and
owner-writable in a world-readable directory**, and the CLI validates almost
nothing about it before trusting its contents. Confirmed on the operator's
machine:

```console
$ ls -la ~/Library/Application\ Support/iMCP/
drwx------    3 user  staff    96 Client Keys
-rw-r--r--    1 user  staff    24 listener-endpoint.json
```

Note the inconsistency: the sibling `Client Keys/` directory is correctly
`0700`, but the endpoint file is `0644` in a `0755` directory.

Any same-user process can rewrite that file to point the CLI at a port it
controls. That matters because it makes the CLI connect to an attacker's
listener instead of iMCP — which puts the attacker in the middle of the user's
entire MCP session in plaintext, and lets it relay the real app's
authentication challenge to the CLI to get it signed with the user's paired key.
A same-user unsandboxed process is explicitly **in scope** for this project's
threat model (`plans/notes/015-security-trust-boundary-design.md:45-55`), and
this is the cheapest path across it.

The CLI's fail-closed Bonjour selection added by plans 017 and 020
(`selectIMCPEndpoint`) is bypassed entirely on the loopback path, so none of
that hardening applies here.

This plan fixes the **file-trust** half: permissions, symlink safety, and owner
verification. It does **not** fix the deeper protocol gap (the CLI will sign a
challenge from any peer, because nothing authenticates the *server*). That
requires a wire-format change and is scoped as a follow-up in Maintenance notes.

## Current state

`App/Shared/ListenerEndpointFile.swift` is compiled into **both** the app and
the CLI. The whole file is 63 lines. The two functions you will change:

```swift
// App/Shared/ListenerEndpointFile.swift:30-38
    static func write(
        port: UInt16,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        in directory: URL = defaultDirectory()
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Contents(port: port, pid: pid))
        try data.write(to: fileURL(in: directory), options: .atomic)
    }
```

```swift
// App/Shared/ListenerEndpointFile.swift:47-57
    static func readValidated(
        in directory: URL = defaultDirectory(),
        isProcessAlive: (Int32) -> Bool = defaultIsProcessAlive
    ) -> Contents? {
        guard let data = try? Data(contentsOf: fileURL(in: directory)),
            let contents = try? JSONDecoder().decode(Contents.self, from: data),
            contents.port > 0,
            isProcessAlive(contents.pid)
        else { return nil }
        return contents
    }
```

Supporting definitions in the same file: `struct Contents: Codable, Equatable
{ let port: UInt16; let pid: Int32 }` (`:14-17`), `fileName` (`:19`),
`defaultDirectory()` (`:21-24`), `fileURL(in:)` (`:26-28`), `remove(in:)`
(`:40-42`), and `defaultIsProcessAlive` (`:59-62`).

The consumer, which you are **not** changing:

```swift
// CLI/main.swift:639-650 (abridged)
                if !skipLoopback,
                    let handoff = ListenerEndpointFile.readValidated(),
                    let port = NWEndpoint.Port(rawValue: handoff.port)
                {
                    endpoint = .hostPort(host: "127.0.0.1", port: port)
                    usedLoopback = true
                }
```

**Repo conventions to match**:
- The existing `0600` write pattern in this repo is
  `CLI/ClientKeyStore.swift:78-93` — `try data.write(to:options:.atomic)`
  followed by
  `try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)`.
  Follow that shape; it is the established idiom here.
- `FileManager.createDirectory` takes explicit attributes via
  `attributes: [.posixPermissions: 0o700]`.
- Existing tests for this file are in `iMCPTests/ListenerEndpointFileTests.swift`
  (75 lines) and inject a temporary directory via the `in directory:` parameter
  and a fake `isProcessAlive` closure. **Model your new tests on that file.**
- `swift format` uses 4-space indentation and a 120-column limit.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| App tests | `xcodebuild test -scheme iMCP -destination "platform=macOS"` | exit 0, `TEST SUCCEEDED` |
| CLI tests | `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` | exit 0, `TEST SUCCEEDED` |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

`-quiet` suppresses the success marker — **success is exit code 0**.

## Scope

**In scope** (the only files you should modify):
- `App/Shared/ListenerEndpointFile.swift`
- `iMCPTests/ListenerEndpointFileTests.swift`

**Out of scope** (do NOT touch, even though they look related):
- `CLI/main.swift` — the caller keeps working unchanged; `readValidated`
  returning `nil` already makes it fall back to Bonjour discovery. Changing
  the CLI's fallback behavior is a separate known finding (see Maintenance
  notes) and editing it here would collide with that work.
- `App/Shared/AuthPreamble.swift` and anything in the pairing/auth path — the
  server-authentication fix is deliberately **not** in this plan.
- `CLI/ClientKeyStore.swift` — it is the pattern to copy, not a file to edit.
- The `Contents` struct's stored fields. Adding a field changes the on-disk
  format; if you believe you need one, STOP and report.

## Git workflow

- Branch: `advisor/031-harden-listener-endpoint-file`
- Conventional commits, e.g.
  `fix: restrict listener endpoint file to owner-only access`.
- Do NOT push or open a PR unless the operator asks.

## Steps

### Step 1: Write the file with owner-only permissions

In `write(port:pid:in:)`:

1. Pass `attributes: [.posixPermissions: 0o700]` to the `createDirectory` call
   so a freshly created directory is owner-only.
2. After the `data.write(to:options:.atomic)` call, set the file's permissions
   to `0o600` using `FileManager.default.setAttributes`, exactly as
   `CLI/ClientKeyStore.swift:88` does.
3. Also tighten the directory when it **already exists** — `createDirectory`
   with `withIntermediateDirectories: true` does not change an existing
   directory's mode, and the operator's directory is already `0755`. Call
   `setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)`
   unconditionally after the create.

Note that `.atomic` writes to a temporary file and renames, so the mode must be
set **after** the write, not before.

**Verify**: build succeeds, then confirm the real file is re-secured after the
app next writes it. Since you cannot run the app, verify via the unit test in
Step 4 instead:

```console
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ `exit=0`.

### Step 2: Reject a file that is not a regular file owned by this user

In `readValidated(in:isProcessAlive:)`, before decoding, add ownership and type
checks on the path. Requirements:

- The path must be a **regular file** — not a symlink, not a directory, not a
  FIFO. Read its attributes with
  `FileManager.default.attributesOfItem(atPath:)`, which does **not** follow
  the final symlink for the `.type` check, and require
  `.type == FileAttributeType.typeRegular`.
- Its owner must be the current user: require the `.ownerAccountID` attribute
  to equal `getuid()`.
- Its mode must not be group- or world-writable: require
  `(posixPermissions & 0o022) == 0`.

If any check fails, return `nil` — the CLI then falls back to Bonjour, which is
the safe direction. Do **not** throw and do not delete the file.

Keep the existing checks (`contents.port > 0`, `isProcessAlive(contents.pid)`)
in place.

Make these checks injectable for testing, in the same style the file already
uses for `isProcessAlive`: add a parameter with a default, e.g.

```swift
    static func readValidated(
        in directory: URL = defaultDirectory(),
        isProcessAlive: (Int32) -> Bool = defaultIsProcessAlive,
        currentUserID: uid_t = getuid()
    ) -> Contents?
```

so a test can assert the rejection path by passing a different uid. Do not
change the existing parameters' names, order, or defaults — existing callers
and tests depend on them.

**Verify**: `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"` → `exit=0`.

### Step 3: Leave a comment recording what this does and does not defend

Add a short doc comment above `readValidated` stating that these checks
establish the file was written by this user and not swapped for a symlink, but
that they do **not** authenticate the process listening on the named port —
that the CLI signs an auth challenge from whatever peer answers, and
server authentication is tracked as a follow-up. Two or three sentences. This
prevents the next reader from assuming the loopback path is fully trusted.

**Verify**: `grep -c "does not authenticate" App/Shared/ListenerEndpointFile.swift` → `1`.

### Step 4: Add tests

In `iMCPTests/ListenerEndpointFileTests.swift`, following the existing
temp-directory pattern in that file, add cases covering:

1. **Write mode** — after `write(port:pid:in:)` into a temp directory, the file's
   `posixPermissions` are `0o600` and the directory's are `0o700`. Read them
   with `FileManager.default.attributesOfItem(atPath:)`.
2. **Existing loose directory is tightened** — pre-create the temp directory
   mode `0o755`, call `write`, assert the directory is `0o700` afterward.
3. **Foreign owner rejected** — write a valid file, then call `readValidated`
   passing a `currentUserID` that differs from `getuid()`; assert `nil`.
4. **Group-writable file rejected** — write a valid file, `chmod` it to `0o620`
   via `setAttributes`, assert `readValidated` returns `nil`.
5. **Symlink rejected** — create a symlink at the endpoint path pointing at a
   valid JSON file elsewhere in the temp directory; assert `readValidated`
   returns `nil`.
6. **Happy path still works** — a normally-written file with a live pid still
   decodes and returns the expected port. This is the regression guard that
   matters most: if this test fails, the CLI can no longer reach the app.

**Verify**: `xcodebuild test -scheme iMCP -destination "platform=macOS" ; echo "exit=$?"` →
`exit=0`, `TEST SUCCEEDED`, and 6 new tests present.

### Step 5: Run the full gate

```console
swift format -i -r .
swift format lint --strict --recursive . ; echo "exit=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS" ; echo "exit=$?"
xcodebuild test -scheme iMCP -destination "platform=macOS" ; echo "exit=$?"
```

The CLI test suite must pass too — `ListenerEndpointFile.swift` is compiled into
the CLI target as well.

**Verify**: all four print `exit=0`.

## Test plan

- New tests in `iMCPTests/ListenerEndpointFileTests.swift`: the six cases in
  Step 4 (write mode, directory tightening, foreign owner, group-writable,
  symlink, happy path).
- Structural pattern: the existing tests in that same file, which already build
  a temp directory and inject `isProcessAlive`.
- Verification: `xcodebuild test -scheme iMCP -destination "platform=macOS"` →
  all pass, including the 6 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "0o600" App/Shared/ListenerEndpointFile.swift` ≥ 1
- [ ] `grep -c "0o700" App/Shared/ListenerEndpointFile.swift` ≥ 1
- [ ] `grep -c "ownerAccountID" App/Shared/ListenerEndpointFile.swift` ≥ 1
- [ ] `grep -c "does not authenticate" App/Shared/ListenerEndpointFile.swift` → `1`
- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `xcodebuild test -scheme iMCP -destination "platform=macOS"` exits 0 with 6 new tests
- [ ] `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` exits 0
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `git status` shows only the two in-scope files modified
- [ ] `plans/README.md` status row for 031 updated

## STOP conditions

Stop and report back (do not improvise) if:

- The happy-path test (Step 4, case 6) fails — that means the CLI can no longer
  reach the app via loopback, which is a functional regression worse than the
  vulnerability being fixed.
- `attributesOfItem(atPath:)` does not expose `.ownerAccountID` or `.type` as
  expected on this platform, forcing a switch to raw `lstat(2)`. That is a
  reasonable implementation but a different one than specified — report before
  doing it.
- You conclude the fix requires changing `CLI/main.swift` or the `Contents`
  on-disk format.
- You discover another writer of this file besides
  `App/Controllers/ServerNetworkManager.swift` (search with
  `grep -rn "ListenerEndpointFile.write" --include=*.swift .`) — a second
  writer would need the same treatment and changes the scope.

## Maintenance notes

For the human/agent who owns this code after the change lands:

- **A reviewer should scrutinize** that `readValidated` returns `nil` (never
  throws, never deletes) on every rejection path — the CLI's Bonjour fallback
  depends on that contract — and that the happy path is genuinely still covered.
- **The larger gap this plan does NOT close**, and which should get its own
  plan: nothing authenticates the *server* to the CLI. `CLI/main.swift:518-529`
  signs **any** `AUTH-CHALLENGE` frame it receives, and the signed payload
  (`App/Shared/AuthPreamble.swift:55-60`) is `nonce ‖ connectionID` — both
  chosen by whoever sends the challenge, with nothing binding it to a socket or
  a server identity. A rogue listener can therefore relay the real app's
  challenge and have the CLI sign it. The fix is to give the app a long-lived
  instance keypair, include its public key and a signature over the challenge
  in the challenge frame, and have the CLI pin that key at pairing time and
  refuse to sign a challenge from an unpinned server. That is a wire-format
  change requiring coordinated app and CLI rollout — plan it separately.
- **Related open finding, not fixed here**: `readValidated`'s liveness check is
  `kill(pid, 0)`, which only proves *some* process with that pid is alive — not
  that it is iMCP or that it owns the named port. Verifying the pid's executable
  path would strengthen this, and pairs naturally with the CLI-fallback fix
  below.
- **Related open finding in the caller**: `CLI/main.swift:667-681` treats
  `StdioProxyError.connectionClosed` as "session was established, terminate",
  but that error also fires when the loopback port is opened and immediately
  closed — so a stale endpoint file pointing at a recycled port makes the CLI
  exit instead of falling back to Bonjour. Fixing that requires a
  "session established" signal from `StdioProxy`; separate plan.
