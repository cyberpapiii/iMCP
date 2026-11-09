# Plan 011: Stop triple-serializing tool results

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- App/Models/Tool.swift App/Controllers/ServerController.swift`
> If either file changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `b84f266`, 2026-07-02

## Why this matters

Every tool result is serialized to JSON, deserialized, and then re-serialized —
up to three passes — before it reaches the client:

1. `Tool.implementation` encodes the tool's typed result to `Data` and
   immediately decodes it back into a generic `Value` (round-trip #1), then
2. the `CallTool` handler re-encodes that `Value` back to a JSON string to put in
   the MCP text content (round-trip #2), and
3. image/audio payloads are additionally base64-re-encoded along the way.

For large results (a full contacts list, a screenshot, an audio clip, 1000+
messages) this is measurable CPU and peak memory — each pass allocates another
full copy — for zero functional benefit; the first encode already produced the
bytes the client needs. After this plan the typed result is encoded once.

## Current state

- `App/Models/Tool.swift` (43 lines) — the round-trip #1 source. The
  `implementation` wrapper (`Tool.swift:24-36`):

```swift
self.implementation = { input in
    let result = try await implementation(input)
    let encoder = JSONEncoder()
    encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] = TimeZone.current
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(result)          // encode typed result -> Data
    let decoder = JSONDecoder()
    return try decoder.decode(Value.self, from: data)   // ...then decode back to Value
}
```

So `implementation` returns a `Value` (already having thrown away the encoded
`Data`).

- `App/Controllers/ServerController.swift` — the `CallTool` handler re-encodes
  that `Value` (round-trip #2), `ServerController.swift:968-975`:

```swift
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
let data = try encoder.encode(value)               // re-encode the Value
let json = String(data: data, encoding: .utf8) ?? "{}"
return .init(content: [.text(json)], isError: false)
```

- Image/audio base64 handling is at `ServerController.swift:948` and `:960`
  (they special-case `Value.data(...)` into `.image`/`.audio` content). Read
  those lines before changing the text path so you don't break binary results.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format (write) | `swift format -i -r .` | exit 0 |
| Format lint (CI gate) | `swift format lint --strict --recursive .` | exit 0, no output |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**:
- `App/Models/Tool.swift`
- `App/Controllers/ServerController.swift` (the `CallTool` result-encoding block only)

**Out of scope**:
- The MCP SDK types (`Value`, `Tool.Content`) — don't modify the dependency.
- The image/audio special-casing behavior — it must keep producing `.image` /
  `.audio` content; you may only remove redundant *re*-encoding, not change which
  content type is emitted.
- Tool input decoding — unchanged.

## Design note (read before editing)

The cleanest fix depends on how the MCP SDK's `Server` wants tool output. There
are two viable shapes; pick the one that fits the SDK version in use and note it:

- **A — carry encoded bytes once**: change `Tool.implementation` to return the
  encoded `Data` (or a small enum of `.json(Data)` / `.binary(mimeType:Data)`)
  instead of decoding back to `Value`. The `CallTool` handler then emits the
  bytes directly as text content (`String(data:encoding:)`) without re-encoding,
  and routes the binary case to `.image`/`.audio`. This removes round-trips #1's
  decode AND #2's encode.
- **B — keep `Value`, encode once**: if downstream code genuinely needs a
  `Value` (e.g. for `ListTools` schemas or logging), keep `implementation`
  returning `Value` but ensure the handler encodes exactly once and nothing
  re-encodes upstream. This removes round-trip #2 only.

A is the bigger win; choose it unless something else consumes the `Value` return
of `implementation` (grep for callers first).

## Steps

### Step 1: Find all consumers of `Tool.implementation`'s return value

`grep -rn "\.implementation(" App` and read each call site. Confirm whether any
consumer other than the `CallTool` handler needs a decoded `Value`. Record the
list in your report — it decides A vs B.

**Verify**: you have an explicit list of `implementation` callers.

### Step 2: Remove the redundant re-encode in CallTool (round-trip #2)

Regardless of A or B, ensure the `CallTool` handler does not re-encode something
that is already encoded. If you keep `Value` (B), the handler encodes once; if
you carry `Data` (A), the handler wraps the existing bytes without re-encoding.
Preserve the `encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`
and the `Ontology.DateTime.timeZoneOverrideKey` timezone override wherever the
single remaining encode happens — these affect output formatting and date
rendering and must not be lost.

**Verify**: read the `CallTool` path — the result is encoded exactly once from
typed data to the string/bytes handed to `.text(...)`.

### Step 3: (If choosing A) collapse round-trip #1 in Tool.swift

Change `Tool.implementation` to stop decoding back to `Value`; return the encoded
representation instead, keeping the timezone override and formatting options on
the single encoder. Update the type of `implementation` and all call sites found
in Step 1.

**Verify**: `Tool.swift` no longer contains `decoder.decode(Value.self, ...)`.

### Step 4: Verify binary results still work

Confirm the image/audio path (`ServerController.swift:948`, `:960`) still emits
`.image`/`.audio` content and is not double-base64-encoded. A screenshot result
should be base64-encoded exactly once.

**Verify**: read the binary branch; trace that the bytes are base64-encoded a
single time.

### Step 5: Format and build

Run `swift format -i -r .` then build.

**Verify**: `** BUILD SUCCEEDED **`; `swift format lint --strict --recursive .` exits 0.

## Test plan

No App-side unit-test target exists yet (plan 014 establishes one). This change
is behavior-preserving, so the key risk is a subtle output difference.
Verification:
- Build clean.
- Manual (record results): if you can run the app, call a text tool (e.g.
  `contacts_me` or `weather_current`) and confirm the JSON returned to the client
  is unchanged from before (same keys, sorted, slashes unescaped, dates in local
  time). Call `capture_take_screenshot` and confirm the image still renders in
  the client. **Byte-for-byte equality of a text result before/after is the
  strongest check** — if you can capture one call's output pre-change, diff it.

## Done criteria

ALL must hold:

- [ ] The `CallTool` result path encodes typed data to JSON exactly once (no
      encode-of-an-already-encoded value)
- [ ] If approach A: `Tool.swift` no longer decodes back to `Value`; all
      `implementation` callers updated
- [ ] `sortedKeys` + `withoutEscapingSlashes` + the `timeZoneOverrideKey`
      override are preserved on the single remaining encoder
- [ ] Image/audio results are base64-encoded exactly once and still emit
      `.image`/`.audio` content
- [ ] `xcodebuild ... build` prints `** BUILD SUCCEEDED **`
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] Only `App/Models/Tool.swift` and `App/Controllers/ServerController.swift` modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- A consumer of `implementation`'s return value genuinely needs a `Value` in a
  way that makes approach A infeasible — fall back to B and note it.
- Removing a round-trip changes the client-visible JSON (key order, slash
  escaping, date format) — the `Value` round-trip may be normalizing something.
  If output differs, STOP and report the diff rather than shipping a behavior
  change.
- The code doesn't match the "Current state" excerpts (drift).

## Maintenance notes

- This is the highest-churn correctness-adjacent path; a reviewer should compare
  actual tool output before/after for at least one text tool and one binary tool.
- If the MCP SDK later exposes a typed-content API that accepts `Encodable`
  directly, this can be simplified further — note that for the future.
