---
title: Measure installed iMCP full-stack performance before optimizing
date: 2026-08-29
category: performance
module: app-cli-runtime
problem_type: performance
component: installed-app-benchmark
severity: medium
applies_when:
  - Measuring MCP latency or throughput
  - Comparing app or CLI runtime optimizations
  - Investigating loaded CPU or memory usage
tags:
  - benchmark
  - mcp
  - startup
  - memory
  - cpu
  - loopback
---

# Measure installed iMCP full-stack performance before optimizing

## Problem

Build duration and unit-test timing do not describe live iMCP performance. The runtime spans a stdio CLI, loopback TCP,
the app's MCP server, service filtering, and JSON encoding. Memory and payload size also change after iCloud restore or
when enabled services change, so an old result is not a valid control for a new candidate.

## Measurement

Run:

```console
Scripts/measure-full-stack-performance.sh
```

The benchmark uses the installed `/Applications/iMCP.app` and bundled `imcp-server`. It reports:

- MCP tool-dispatch p50 and p95 latency using an invalid, silent `utilities_beep` argument.
- Cold relaunch-to-ready p50 and p95 duration.
- App RSS with four connected CLI sessions and peak RSS during load.
- App CPU during three seconds of sustained MCP dispatch. Values can exceed 100% on multicore macOS.
- `tools/list` JSON throughput over loopback TCP. This is application throughput, not raw network bandwidth.
- Connection, app-relaunch, and stable-tool-catalog gates.

Default five-run baseline on 2026-08-29:

| Metric | Baseline |
| --- | ---: |
| MCP dispatch p50 | 0.48 ms |
| MCP dispatch p95 | 1.43 ms |
| Startup p50 | 1,335.14 ms |
| Startup p95 | 2,330.56 ms |
| Connected app RSS | 99.8 MB |
| Peak app RSS | 104.47 MB |
| Loaded app CPU | 200.7% |
| `tools/list` throughput | 40.8465 Mbps |
| Calls per second | 205.12 |

All reliability gates passed at 100%.

Final five-run live checkpoint, after restoring unchanged runtime code:

| Metric | Final live value |
| --- | ---: |
| MCP dispatch p50 | 0.48 ms |
| Startup p50 | 1,293.47 ms |
| Connected app RSS | 129.95 MB |
| Loaded app CPU | 203.4% |
| `tools/list` throughput | 28.3244 Mbps |

Reliability gates again passed at 100%. Initial and final runtime code were identical. The higher RSS and lower
throughput coincide with restored iCloud/service state and a smaller 22,937-byte tool payload, so they are live-state
drift rather than a code regression.

## Comparison discipline

Install and measure a fresh control immediately before each candidate. Compare paired samples with a 5% threshold.
Do not keep a change because one noisy sample moved. During this run, later iCloud and service state increased RSS to
about 130 MB and reduced the tool-list payload from 24,892 to 22,937 bytes; comparing those samples directly with the
initial baseline would have produced false regressions.

Two code candidates were rejected:

1. Caching enabled MCP tool arrays made no consistent metric move. Tool filtering was not hot.
2. Cursor-based app receive scanning averaged 6% lower dispatch latency, but paired improvements were 4% and 8%, so it
   failed the consistency gate. Other required metrics stayed within 5%.

No runtime change was kept. This avoids shipping complexity with unproven benefit.

## Profile result

A five-second sample under sustained dispatch showed the dominant app work inside MCP SDK `Value` JSON decoding.
String arguments repeatedly entered data-URL detection and regex compilation. Allocation, retain/release, JSON decoding,
and regex machinery dominated active stacks; service filtering and receive-buffer tail copies did not.

MCP Swift SDK 0.12.1 was also tested. It leaves data-URL regex construction unchanged and reduced paired tool-list
throughput by 25.6%, so iMCP remains on 0.12.0. The highest-value next experiment needs a future upstream release that
caches or avoids repeated regex compilation; re-run paired measurements and the full compatibility suite before adoption.
