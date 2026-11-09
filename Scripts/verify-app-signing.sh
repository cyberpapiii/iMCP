#!/usr/bin/env bash
set -euo pipefail

# The only place these two codesign outputs are parsed. Both print nothing,
# and still exit 0, for an unsigned or unreadable bundle.
print_authority() {
  codesign -dv --verbose=4 "$1" 2>&1 | awk -F= '/^Authority=/ {print $2; exit}' || true
}
print_requirement() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p' || true
}
case "${1:-}" in
  --print-authority) print_authority "${2:?app bundle path}"; exit 0 ;;
  --print-requirement) print_requirement "${2:?app bundle path}"; exit 0 ;;
esac

APP_BUNDLE="${1:-}"
ALLOW_ADHOC="${IMCP_ALLOW_ADHOC:-0}"

if [[ -z "${APP_BUNDLE}" || ! -d "${APP_BUNDLE}" ]]; then
  echo "usage: $0 /path/to/iMCP.app" >&2
  exit 2
fi

codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

ENTITLEMENTS_PLIST="$(mktemp "${TMPDIR:-/tmp}/imcp-entitlements.XXXXXX")"
cleanup() {
  rm -f "${ENTITLEMENTS_PLIST}"
}
trap cleanup EXIT

# codesign writes both diagnostics and the plist to stderr. Keep only the plist.
codesign -d --entitlements :- "${APP_BUNDLE}" 2>&1 \
  | sed -n '/^<?xml/,$p' > "${ENTITLEMENTS_PLIST}"

if [[ ! -s "${ENTITLEMENTS_PLIST}" ]]; then
  echo "error: ${APP_BUNDLE} has no readable signed entitlements" >&2
  exit 1
fi

assert_true_entitlement() {
  local key="$1"
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :${key}" "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
  if [[ "${value}" != "true" ]]; then
    echo "error: missing required entitlement: ${key}" >&2
    exit 1
  fi
}

assert_false_or_missing_entitlement() {
  local key="$1"
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :${key}" "${ENTITLEMENTS_PLIST}" 2>/dev/null || true)"
  if [[ "${value}" == "true" ]]; then
    echo "error: incompatible entitlement is enabled: ${key}" >&2
    exit 1
  fi
}

# App Sandbox would block FDA-protected databases even after TCC grants access.
assert_false_or_missing_entitlement "com.apple.security.app-sandbox"
# Routine Find My People reads must not gain injection or dynamic-code bypass
# privileges. The one-time debugger capture is a separate human-run script.
assert_false_or_missing_entitlement "com.apple.security.cs.disable-library-validation"
assert_false_or_missing_entitlement "com.apple.security.cs.allow-dyld-environment-variables"
assert_false_or_missing_entitlement "com.apple.private.security.no-container"
# Every entitlement App.Debug.entitlements turns on is one Debug, CI, and
# Release builds all claim; CI and Release only remove or add other keys.
DEBUG_ENTITLEMENTS="$(dirname "${BASH_SOURCE[0]}")/../App/App.Debug.entitlements"
required_keys="$(/usr/bin/python3 -I -c '
import plistlib, sys
with open(sys.argv[1], "rb") as source:
    print("\n".join(key for key, value in plistlib.load(source).items() if value is True))
' "${DEBUG_ENTITLEMENTS}")"
if [[ -z "${required_keys}" ]]; then
  echo "error: no required entitlements read from ${DEBUG_ENTITLEMENTS}" >&2
  exit 1
fi
while IFS= read -r key; do
  assert_true_entitlement "${key}"
done <<<"${required_keys}"

DESIGNATED_REQUIREMENT="$(print_requirement "${APP_BUNDLE}")"
if [[ -z "${DESIGNATED_REQUIREMENT}" ]]; then
  if [[ "${ALLOW_ADHOC}" != "1" ]]; then
    echo "error: ${APP_BUNDLE} has no designated requirement" >&2
    exit 1
  fi
  DESIGNATED_REQUIREMENT="ad hoc build (allowed for pre-install verification)"
fi

echo "Verified signing and required entitlements: ${APP_BUNDLE}"
echo "Designated requirement: ${DESIGNATED_REQUIREMENT}"
