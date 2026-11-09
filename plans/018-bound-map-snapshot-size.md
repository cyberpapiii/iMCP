# Plan 018: Bound `maps_generate` snapshot dimensions

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- App/Services/Maps.swift`
> If `App/Services/Maps.swift` changed since this plan was written, compare the
> "Current state" excerpt against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `b84f266`, 2026-07-03

## Why this matters

`maps_generate` lets a connected MCP client ask MapKit for a static image. Its
schema advertises `width` and `height`, but neither the schema nor implementation
sets minimum or maximum dimensions. A trusted client can request very large
images, forcing expensive snapshot and TIFF-to-PNG work inside the app. The
default is already 1024x1024, which is enough for most LLM/image use. This plan
adds explicit bounds so the tool remains useful while failing fast on oversized
requests.

## Current state

- `App/Services/Maps.swift` - Maps service; `maps_generate` creates an
  `MKMapSnapshotter.Options` and returns PNG data.

Current defaults, `App/Services/Maps.swift:8-10`:

```swift
private let defaultSearchRadius: CLLocationDistance = 5000  // Default 5km
private let defaultSearchLimit: Int = 10
private let defaultMapImageSize: CGSize = CGSize(width: 1024, height: 1024)
```

Schema currently declares dimensions without bounds,
`App/Services/Maps.swift:462-469`:

```swift
"width": .integer(
    description: "Image width in pixels",
    default: .int(Int(defaultMapImageSize.width))
),
"height": .integer(
    description: "Image height in pixels",
    default: .int(Int(defaultMapImageSize.height))
),
```

Implementation accepts those dimensions directly,
`App/Services/Maps.swift:521-545`:

```swift
let width = arguments["width"]?.intValue ?? Int(defaultMapImageSize.width)
let height = arguments["height"]?.intValue ?? Int(defaultMapImageSize.height)
...
options.size = CGSize(width: width, height: height)
```

The snapshot is then converted through TIFF and PNG data at
`App/Services/Maps.swift:601-621`, so very large dimensions amplify memory and
CPU use.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format (write) | `swift format -i -r .` | exit 0 |
| Format lint | `swift format lint --strict --recursive .` | exit 0, no output |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| CLI tests | `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` | `** TEST SUCCEEDED **` |

## Scope

**In scope**:
- `App/Services/Maps.swift`

**Out of scope**:
- Changing MapKit search, directions, ETA, or POI behavior.
- Changing image format support.
- Adding global rate limiting for tool calls.
- Adding App tests or editing `iMCP.xcodeproj/project.pbxproj`; plan 014 owns
  App test-target setup.

## Git workflow

- Branch: `advisor/018-bound-map-snapshot-size`
- Single commit; short imperative message, e.g. "Bound map snapshot dimensions".
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add named dimension bounds

Near `defaultMapImageSize`, add constants for minimum and maximum generated map
image dimensions. Use conservative values:

```swift
private let minMapImageDimension = 128
private let maxMapImageDimension = 2048
```

2048 preserves high-resolution utility while preventing runaway requests. If the
maintainer has a documented product requirement for larger images, STOP and ask
for the intended bound.

**Verify**:
`grep -n "maxMapImageDimension\\|minMapImageDimension" App/Services/Maps.swift`
-> both constants exist.

### Step 2: Declare bounds in the JSON schema

Add `minimum` and `maximum` to the `width` and `height` schema entries using the
new constants:

```swift
"width": .integer(
    description: "Image width in pixels",
    default: .int(Int(defaultMapImageSize.width)),
    minimum: minMapImageDimension,
    maximum: maxMapImageDimension
),
```

Apply the same shape to `height`. Match the file's existing formatting and
trailing comma style.

**Verify**:
`grep -n "maximum: maxMapImageDimension\\|minimum: minMapImageDimension" App/Services/Maps.swift`
-> four matches total, two for width and two for height if each argument is on
its own line.

### Step 3: Enforce bounds at runtime

Do not rely only on schema validation. Reject invalid values before constructing
`CGSize` so clients learn the contract:

```swift
guard (minMapImageDimension ... maxMapImageDimension).contains(width),
    (minMapImageDimension ... maxMapImageDimension).contains(height)
else {
    throw NSError(
        domain: "MapsServiceError",
        code: 16,
        userInfo: [
            NSLocalizedDescriptionKey:
                "Map image width and height must be between \(minMapImageDimension) and \(maxMapImageDimension) pixels"
        ]
    )
}
```

Place the guard after reading `width`/`height` and before creating
`MKMapSnapshotter.Options`.

**Verify**:
`grep -n "Map image width and height must be between\\|code: 16" App/Services/Maps.swift`
-> shows the runtime validation.

### Step 4: Format, build, and test

Run:

```console
swift format -i -r .
swift format lint --strict --recursive .
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"
```

**Verify**: format lint exits 0; build exits 0; tests print `** TEST SUCCEEDED **`.

## Test plan

- No App-side service test target currently exists; do not create one here.
- Verify by build and source inspection for this small validation change.
- Follow-up after plan 014: add unit coverage for a factored helper such as
  `validatedMapImageSize(width:height:)` covering default, boundary, and
  out-of-range dimensions.

## Done criteria

ALL must hold:

- [ ] `width` and `height` schemas both declare min/max bounds
- [ ] Runtime validation rejects dimensions outside the same bounds before
      constructing `MKMapSnapshotter.Options`
- [ ] Default 1024x1024 remains valid
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `xcodebuild ... build` exits 0
- [ ] `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` prints `** TEST SUCCEEDED **`
- [ ] Only `App/Services/Maps.swift` and `plans/README.md` modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- `JSONSchema.integer` does not accept `minimum`/`maximum` Int arguments in this
  package version. In that case, keep runtime validation and report the schema
  limitation instead of inventing a new schema abstraction.
- A product requirement demands images larger than 2048 pixels on either side.
  Ask for the intended cap before choosing a different value.
- Adding test coverage requires creating or editing an App test target; that is
  plan 014/follow-up work, not this plan.

## Maintenance notes

- This plan bounds one expensive tool. It does not provide global per-client
  rate limiting, cancellation, or response-size quotas; those are separate
  security/performance concerns.
- Reviewer should confirm the error message is client-friendly and that schema
  and runtime bounds stay in sync.
