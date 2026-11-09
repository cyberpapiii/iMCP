#!/usr/bin/env bash
# Stable wrapper for full-stack installed-app performance measurements.
# Emits exactly one JSON object on stdout; diagnostics go to stderr.
#
# The spawned imcp-server must use a client key the app already approved, or
# the run stops at the first initialize. Debug builds read the key from
# IMCP_KEY_FILE, which child processes inherit.
#
# BENCH_RUNS, BENCH_STARTUP_RUNS, BENCH_LOAD_CALLS, BENCH_CPU_LOAD_MS,
# BENCH_CONCURRENCY, and BENCH_TIMEOUT_MS override the benchmark's defaults.

set -euo pipefail

# shellcheck source=lib/imcp.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/imcp.sh"
BINARY="${IMCP_BENCH_BINARY:-${CLI_EXECUTABLE}}"

if [[ ! -d "${INSTALL_APP}" ]]; then
  printf '{"harness_error":"installed iMCP app not found"}\n'
  exit 2
fi
if [[ ! -x "${BINARY}" ]]; then
  printf '{"harness_error":"installed imcp-server not found"}\n'
  exit 2
fi

arguments=(--app "${INSTALL_APP}" --app-executable "${APP_EXECUTABLE}" --binary "${BINARY}")
add_override() {
  if [[ -n "${2:-}" ]]; then
    arguments+=("$1" "$2")
  fi
}
add_override --runs "${BENCH_RUNS:-}"
add_override --startup-runs "${BENCH_STARTUP_RUNS:-}"
add_override --load-calls "${BENCH_LOAD_CALLS:-}"
add_override --cpu-load-ms "${BENCH_CPU_LOAD_MS:-}"
add_override --concurrency "${BENCH_CONCURRENCY:-}"
add_override --timeout-ms "${BENCH_TIMEOUT_MS:-}"

# The benchmark stops and starts the app itself. Paused, the watchdog and the
# clients' imcp-server processes cannot relaunch it in between. The benchmark
# spawns its own imcp-server sessions afterwards, so those run.
trap imcp_resume_relaunchers EXIT
if ! imcp_pause_relaunchers; then
  printf '{"harness_error":"could not pause the processes that relaunch iMCP"}\n'
  exit 2
fi

/usr/bin/env node "${IMCP_ROOT_DIR}/Scripts/bench-full-stack-performance.mjs" "${arguments[@]}"
