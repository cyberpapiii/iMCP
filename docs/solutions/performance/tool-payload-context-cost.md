---
title: Trim MCP payload bytes that carry no information
date: 2026-08-31
category: performance
module: app-tool-surface
problem_type: performance
component: tool-schemas-and-responses
severity: medium
applies_when:
  - Adding or changing a tool schema
  - Adding a response model that carries coordinates or measurements
  - Investigating how much context an iMCP session costs a client
tags:
  - mcp
  - payload
  - context
  - tokens
  - json-schema
  - location
---

# Trim MCP payload bytes that carry no information

## Problem

Every byte iMCP returns lands in a model's context window. Two kinds of byte
cost nothing to remove because they carry no information the caller can use:

1. **Schema shapes that say the same thing at three times the length.** A set
   of allowed strings written as `anyOf` of `const` subschemas encodes the
   same constraint as one `enum`, but each value pays for its own `{"const":
   …,"type":"string"}` wrapper. The `showPointsOfInterest` categories in
   `maps_generate` cost 705 bytes as `anyOf`/`const` and 230 as `enum`, in
   every `tools/list` reply of every session.

2. **Floating-point digits past the precision of the measurement.** Swift's
   `JSONEncoder` writes a `Double` at full round-trip precision, so a
   coordinate went out as `40.73385992982547` and an accuracy radius as
   `9.635369796145278`. No fix iMCP can read is precise past six decimal
   places (about 11 cm), and an accuracy estimate is not precise past a
   decimetre. Long digit runs also tokenize badly, so the context cost is
   worse than the byte cost suggests.

## Fix

`App/Services/Maps.swift` builds the category list with
`.string(enum: …)` instead of `.anyOf(… .string(const: …))`. The accepted
values are identical.

`App/Location/LocationService.swift` rounds at the point where a response model is
built: `roundedDegrees` for latitude and longitude, `roundedMeters` for
accuracy radii and place radii. `iMCPTests/PlaceNameCacheTests.swift` holds
`LocationRoundingTests`, which pins the six-decimal rule and asserts the
resulting position error stays under 12 cm.

## Measured result

Installed app, same enabled services, measured with a since-removed client
benchmark (use `Scripts/measure-full-stack-performance.sh` now) and direct tool calls:

| Payload | Before | After | Change |
| --- | ---: | ---: | ---: |
| `tools/list` (26 tools) | 22,934 B | 22,429 B | −2.2% |
| `location_history` (default range) | 206.5 B/sample | 178.3 B/sample | −13.7% |
| `location_visits` | 2,501 B | 2,341 B | −6.4% |
| `location_people` | 297 B | 266 B | −10.4% |
| `location_devices` | 2,155 B | 2,078 B | −3.6% |

Per-sample bytes are the fair comparison for `location_history`; the sample
count moves between runs as the sampler records new fixes.

## Second pass (2026-09-02): one name per parameter

Six tools documented the same date bound under two spellings (`start` and
`startDate`, `end` and `endDate`), each with its own description, and
`contacts_update` documented its identifier as both `@id` and `identifier`.
The schemas now carry one name each: `startDate`/`endDate` for every range
query, `identifier` for the contact. Each date argument's explicit `alias:`
(`ToolArgument.date`) and `ContactsService.identifier` still accept the other
spelling at call time, so a client that learned the old name keeps working.

The `@id` removal also fixes a functional bug: the Anthropic API rejects tool
property names outside `[a-zA-Z0-9_.-]`, so any Claude client dropped
`contacts_update` from its tool list entirely.

`ToolSchemaHygieneTests` in `iMCPTests/CallToolDispatchTests.swift` pins both
rules against the live registry: every property name is client-safe, and no
parameter is documented twice.

| Payload | Before | After | Change |
| --- | ---: | ---: | ---: |
| `tools/list` (26 tools, Calendar and Screen Time off) | 22,429 B | 22,052 B | −1.7% |

With Calendar and Screen Time enabled the saving is roughly 1.5 KB more,
since those services carried four of the six alias pairs.

## What is left, and why it was not done

The schemas are now close to their floor: property names, one-line
descriptions, and enums. The remaining `tools/list` cost is latency, not
bytes, and it sits in the upstream swift-sdk `Value` decoder (see the
2026-08-23 measurement in the ce-optimize digest); it needs an upstream pull
request or a fork pin, which the owner declined.


44% of a `location_history` reply is repeated JSON key names — 250 samples
each spelling out `horizontalAccuracyMeters`. A columnar or short-key shape
would cut the reply roughly in half, but it changes the response contract
every existing client reads, so it needs an owner decision rather than an
optimization pass.
