#!/usr/bin/env bash
set -uo pipefail

# Reports the state of the local install. Changes nothing, and exits non-zero
# only when a check fails outright, so it is safe to run at any time.
#
# The checks are the ones that explain a permission or sign-in prompt appearing
# again: a changed signing identity voids the TCC grants, and a missing keychain
# access group sends every secret back to the file keychain, whose per-binary
# ACL is what makes macOS ask.

# shellcheck source=lib/imcp.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/imcp.sh"
SIGNING="${IMCP_ROOT_DIR}/Scripts/verify-app-signing.sh"
failures=0

pass() { printf '  ok    %s\n' "$1"; }
warn() { printf '  warn  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

echo "Installed app"
if [[ ! -d "${INSTALL_APP}" ]]; then
  fail "${INSTALL_APP} is not installed -- run Scripts/install-local.sh run"
  exit 1
fi

authority="$("${SIGNING}" --print-authority "${INSTALL_APP}")"
case "$(imcp_authority_kind "${authority}")" in
  adhoc) fail "no signing authority; the app is ad-hoc signed and will lose its grants on every rebuild" ;;
  development) pass "signed by ${authority}" ;;
  *) warn "signed by ${authority}" ;;
esac

installed_requirement="$("${SIGNING}" --print-requirement "${INSTALL_APP}")"
if [[ -n "${installed_requirement}" ]]; then
  pass "designated requirement: ${installed_requirement}"
else
  fail "could not read the designated requirement"
fi

echo
echo "App facts"
# The app reports the Keychain services, bundle id, and paths it uses. A build older than
# --doctor-facts would ignore the flag and start a second copy of the app, so
# the flag has to be in the binary first. A Debug build keeps its code in
# iMCP.debug.dylib beside a stub executable, so look in both.
keychain_services=()
if ! grep -aqsF -- "--doctor-facts" "${APP_EXECUTABLE}" "${APP_EXECUTABLE}.debug.dylib"; then
  fail "the installed build predates --doctor-facts -- reinstall with Scripts/install-local.sh run"
elif ! facts="$("${APP_EXECUTABLE}" --doctor-facts 2>&1)"; then
  fail "could not read the app's facts: ${facts}"
else
  while IFS='=' read -r key value; do
    case "${key}" in
      configuration) pass "build configuration: ${value}" ;;
      keychain-service) keychain_services+=("${value}") ;;
      bundle-id)
        if [[ "${value}" == "${BUNDLE_ID}" ]]; then
          pass "bundle id: ${value}"
        else
          fail "the app is ${value}, but Scripts/lib/imcp.sh says ${BUNDLE_ID}"
        fi
        ;;
      app-support-dir)
        if [[ "${value}" == "${APP_SUPPORT_DIR}" ]]; then
          pass "Application Support: ${value}"
        else
          fail "the app uses ${value}, but Scripts/lib/imcp.sh says ${APP_SUPPORT_DIR}"
        fi
        ;;
      endpoint-file)
        if [[ "${value}" == "${ENDPOINT_FILE}" ]]; then
          pass "listener endpoint file: ${value}"
        else
          fail "the app writes ${value}, but Scripts/lib/imcp.sh reads ${ENDPOINT_FILE}"
        fi
        ;;
    esac
  done <<<"${facts}"
fi

echo
echo "Keychain access"
if codesign -d --entitlements - "${INSTALL_APP}" 2>/dev/null | grep -q keychain-access-groups; then
  pass "the bundle claims a keychain access group"
else
  fail "no keychain-access-groups entitlement -- secrets fall back to the file keychain and macOS will prompt"
fi

if [[ -f "${INSTALL_APP}/Contents/embedded.provisionprofile" ]]; then
  pass "a provisioning profile is embedded, which is what authorizes that group"
else
  fail "no embedded provisioning profile -- build with -allowProvisioningUpdates"
fi

for service in ${keychain_services[@]+"${keychain_services[@]}"}; do
  if security find-generic-password -s "${service}" >/dev/null 2>&1; then
    warn "${service} still has a copy in the file keychain (harmless: the app reads the data-protection copy, and deleting this one would itself need the ACL prompt)"
  else
    pass "${service} is not in the file keychain"
  fi
done

if denial_log="$(/usr/bin/log show --last 1h --style compact \
  --predicate "$(imcp_log_predicate) AND eventMessage CONTAINS \"-34018\"" 2>/dev/null)"; then
  recent_denials="$(printf '%s\n' "${denial_log}" | grep -c -- '-34018')"
  if [[ "${recent_denials}" == "0" ]]; then
    pass "no errSecMissingEntitlement in the last hour of app logs"
  else
    fail "${recent_denials} keychain entitlement denials in the last hour"
  fi
else
  warn "could not read the unified log, so keychain denials were not checked"
fi

echo
echo "Processes"
if [[ -n "$(imcp_app_pids)" ]]; then
  pass "the app is running"
  if imcp_is_ready; then
    pass "the app has published its listener endpoint"
  else
    warn "the app has not published its listener endpoint -- is iMCP turned on?"
  fi
else
  warn "the app is not running -- open -a iMCP"
fi

if [[ -n "$(imcp_watchdog_pids)" ]]; then
  pass "the always-on watchdog is running"
else
  warn "the always-on watchdog is not running -- ${APP_EXECUTABLE} --always-on on, then approve it under System Settings > General > Login Items & Extensions"
fi

echo
echo "iCloud session"
# The app reads its own data-protection Keychain item; `security` cannot.
if icloud_status="$("${APP_EXECUTABLE}" --icloud-status 2>&1)"; then
  printf '%s\n' "${icloud_status}" | sed 's/^/  /'
else
  warn "could not read the iCloud snapshot: ${icloud_status}"
fi

echo
if ((failures > 0)); then
  echo "${failures} check(s) failed."
  exit 1
fi
echo "All checks passed."
