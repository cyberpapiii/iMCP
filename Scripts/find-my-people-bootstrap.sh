#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---dry-run}"
# shellcheck source=lib/imcp.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/imcp.sh"
ROOT="${IMCP_ROOT_DIR}"
ARTIFACTS="${ROOT}/Scripts/find_my_people_artifacts.py"
artifact_path() { /usr/bin/python3 -I "${ARTIFACTS}" path "${APP_SUPPORT_DIR}" "$1"; }
ARTIFACT_DIR="$(artifact_path directory)"
HANDOFF="$(artifact_path handoff)"
ENVELOPE="$(artifact_path envelope)"
BASELINE="$(artifact_path baseline)"
RESTORATION="$(artifact_path restoration)"
CAPTURE_TIMEOUT_SECONDS=300

ensure_artifact_directory() {
  [[ ! -L "${ARTIFACT_DIR}" ]] || { echo "refusing a symlinked artifact directory" >&2; exit 1; }
  /bin/mkdir -p "${ARTIFACT_DIR}"
  [[ -d "${ARTIFACT_DIR}" && ! -L "${ARTIFACT_DIR}" ]] || {
    echo "artifact directory is unavailable" >&2
    exit 1
  }
  /bin/chmod 700 "${ARTIFACT_DIR}"
  [[ "$(/usr/bin/stat -f '%u' "${ARTIFACT_DIR}")" == "${UID}" ]] || {
    echo "artifact directory is not owned by the current user" >&2
    exit 1
  }
  [[ "$(/usr/bin/stat -f '%g' "${ARTIFACT_DIR}")" == "$(/usr/bin/id -g)" ]] || {
    echo "artifact directory has an unexpected group" >&2
    exit 1
  }
}

preflight() {
  for tool in /usr/bin/lldb /usr/bin/openssl /usr/bin/python3 /usr/bin/pgrep /bin/ps; do
    [[ -x "${tool}" ]] || { echo "missing bootstrap dependency" >&2; exit 1; }
  done
  ensure_artifact_directory
  [[ -f "${HANDOFF}" && ! -L "${HANDOFF}" ]] || { echo "prepare setup in iMCP first" >&2; exit 1; }
  /usr/bin/python3 -I "${ARTIFACTS}" check-handoff "${HANDOFF}"
  # shellcheck disable=SC2207 # pgrep prints one numeric PID per line; splitting is intended and bash 3.2 has no mapfile
  PIDS=($(/usr/bin/pgrep -x findmylocateagent))
  [[ "${#PIDS[@]}" -eq 1 ]] || { echo "expected exactly one findmylocateagent" >&2; exit 1; }
  [[ "$(/bin/ps -p "${PIDS[0]}" -o comm=)" == "/usr/libexec/findmylocateagent" ]] || {
    echo "refusing non-canonical Apple process" >&2
    exit 1
  }
  [[ ! -e "${ENVELOPE}" && ! -L "${ENVELOPE}" ]] || {
    echo "refusing to overwrite an existing envelope entry" >&2
    exit 1
  }
}

case "${MODE}" in
  --dry-run)
    "${ROOT}/Scripts/verify-find-my-people-security.sh" --dry-run
    echo "dry-run: capture prerequisites inspected only when a prepared handoff exists; no attachment or mutation performed"
    ;;
  status)
    if [[ -f "${HANDOFF}" ]]; then echo "handoff: ready"; else echo "handoff: missing"; fi
    if [[ -f "${ENVELOPE}" ]]; then echo "envelope: captured"; else echo "envelope: missing"; fi
    if [[ -f "${RESTORATION}" ]]; then echo "restoration report: ready"; else echo "restoration report: missing"; fi
    ;;
  preflight)
    preflight
    echo "capture preflight passed; this command did not attach a debugger"
    ;;
  baseline)
    ensure_artifact_directory
    [[ ! -e "${BASELINE}" && ! -L "${BASELINE}" ]] || {
      echo "remove or archive the old baseline first" >&2
      exit 1
    }
    exec sudo "${ROOT}/Scripts/verify-find-my-people-security.sh" baseline "${BASELINE}"
    ;;
  capture)
    preflight
    PID="$(/usr/bin/pgrep -x findmylocateagent)"
    /usr/bin/python3 - "${PID}" "${ROOT}/Scripts/find_my_people_key.py" "${HANDOFF}" "${ENVELOPE}" \
      "${CAPTURE_TIMEOUT_SECONDS}" <<'PY'
import os
import shlex
import signal
import stat
import subprocess
import sys

pid, module, handoff, envelope, timeout = sys.argv[1:]
command = [
    "/usr/bin/sudo",
    "/usr/bin/lldb",
    "-b",
    "-p",
    pid,
    "-o",
    f"command script import {shlex.quote(module)}",
    "-o",
    f"imcp_find_my_people_capture {shlex.quote(handoff)} {shlex.quote(envelope)}",
    "-o",
    "continue",
    "-o",
    "process detach",
    "-o",
    "quit",
]
process = subprocess.Popen(command, preexec_fn=os.setpgrp)


def interrupted(_signal, _frame):
    raise InterruptedError


signal.signal(signal.SIGINT, interrupted)
signal.signal(signal.SIGTERM, interrupted)
try:
    status = process.wait(timeout=int(timeout))
    if status == 0:
        try:
            if not stat.S_ISREG(os.lstat(envelope).st_mode):
                status = 1
        except FileNotFoundError:
            status = 1
except subprocess.TimeoutExpired:
    print("capture timed out; terminating the debugger", file=sys.stderr)
    status = 124
except InterruptedError:
    print("capture interrupted; terminating the debugger", file=sys.stderr)
    status = 130
finally:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
sys.exit(status)
PY
    ;;
  verify-restored)
    ensure_artifact_directory
    [[ -f "${ENVELOPE}" && ! -L "${ENVELOPE}" ]] || { echo "encrypted envelope is missing" >&2; exit 1; }
    [[ ! -e "${RESTORATION}" && ! -L "${RESTORATION}" ]] || {
      echo "remove the old restoration report first" >&2
      exit 1
    }
    exec sudo "${ROOT}/Scripts/verify-find-my-people-security.sh" restoration "${RESTORATION}" "${ENVELOPE}"
    ;;
  cleanup)
    rm -f "${ENVELOPE}" "${RESTORATION}"
    echo "removed encrypted staging artifacts; use Cancel Setup in iMCP to remove the handoff and private key"
    ;;
  *)
    echo "usage: $0 --dry-run|status|baseline|preflight|capture|verify-restored|cleanup" >&2
    exit 2
    ;;
esac
