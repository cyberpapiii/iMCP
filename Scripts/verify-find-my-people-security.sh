#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-status}"
OUTPUT="${2:-}"
ENVELOPE="${3:-}"
ARTIFACTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/find_my_people_artifacts.py"

usage() {
  echo "usage: $0 status | --dry-run | baseline OUTPUT | restoration OUTPUT ENVELOPE" >&2
  exit 2
}

case "${MODE}" in
  status|--dry-run) ;;
  baseline) [[ -n "${OUTPUT}" ]] || usage ;;
  restoration) [[ -n "${OUTPUT}" && -n "${ENVELOPE}" ]] || usage ;;
  *) usage ;;
esac

for tool in /usr/bin/csrutil /usr/bin/bputil /usr/sbin/nvram /usr/sbin/DevToolsSecurity /usr/sbin/sysctl /usr/bin/python3; do
  [[ -x "${tool}" ]] || { echo "missing required system tool" >&2; exit 1; }
done

if [[ "${MODE}" == "--dry-run" ]]; then
  echo "dry-run: dependencies present; no sudo, policy change, reboot, debugger, or file write performed"
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "verification requires an explicit user-run sudo invocation so bputil can attest Full Security" >&2
  exit 1
fi

BPUTIL_OUTPUT="$(/usr/bin/bputil -d 2>&1)"
if grep -Eiq 'Full Security|security mode[^[:alnum:]]+full' <<<"${BPUTIL_OUTPUT}"; then
  FULL_SECURITY=true
else
  echo "could not prove Full Security" >&2
  exit 1
fi

SIP_OUTPUT="$(/usr/bin/csrutil status 2>&1)"
ROOT_OUTPUT="$(/usr/bin/csrutil authenticated-root status 2>&1)"
grep -Eiq 'status: enabled' <<<"${SIP_OUTPUT}" || { echo "SIP is not fully enabled" >&2; exit 1; }
grep -Eiq 'status: enabled' <<<"${ROOT_OUTPUT}" || { echo "authenticated root is not enabled" >&2; exit 1; }

BOOT_ARGS="$(/usr/sbin/nvram boot-args 2>/dev/null || true)"
if grep -Eiq 'amfi_get_out_of_my_way|amfi_allow_any_signature|cs_enforcement_disable|task_for_pid-allow|kext-dev-mode|(^|[[:space:]])debug($|[=[:space:]])' <<<"${BOOT_ARGS}"; then
  echo "a debugger, AMFI, code-signing, or kernel weakening boot argument is present" >&2
  exit 1
fi

DEVELOPER_OUTPUT="$(/usr/sbin/DevToolsSecurity -status 2>&1)"
if grep -Eiq 'enabled' <<<"${DEVELOPER_OUTPUT}"; then DEVELOPER=true; else DEVELOPER=false; fi
BOOT_UUID="$(/usr/sbin/sysctl -n kern.bootsessionuuid)"

if [[ "${MODE}" == "status" ]]; then
  echo "security status: Full Security, SIP, authenticated root, and boot arguments passed"
  echo "developer tools security enabled: ${DEVELOPER}"
  exit 0
fi

[[ "${SUDO_UID:-}" =~ ^[0-9]+$ && "${SUDO_GID:-}" =~ ^[0-9]+$ && "${SUDO_UID}" -gt 0 ]] || {
  echo "report creation requires an explicit sudo invocation by a non-root user" >&2
  exit 1
}

# -I keeps this root interpreter off the invoking user's PYTHON* variables,
# user site-packages, and the script's own directory.
/usr/bin/python3 -I "${ARTIFACTS}" report \
  "${MODE}" "${OUTPUT}" "${ENVELOPE}" "${FULL_SECURITY}" "${DEVELOPER}" "${BOOT_UUID}"

echo "wrote a metadata-only ${MODE} report (not an authoritative cryptographic receipt)"
