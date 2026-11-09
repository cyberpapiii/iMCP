#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/imcp.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/imcp.sh"
ROOT_DIR="${IMCP_ROOT_DIR}"
SOURCE_APP="${DERIVED_DATA_PATH}/Build/Products/Debug/iMCP.app"
SIGN_IDENTITY="${IMCP_SIGN_IDENTITY:-}"
BACKUP_DIR="${APP_SUPPORT_DIR}/Local Install Backups"
STAGE_ROOT=""
# This path is removed with rm -rf before the new bundle moves in.
if [[ "${INSTALL_APP}" != /*/iMCP.app ]]; then
  echo "error: IMCP_INSTALL_APP must be an absolute path ending in /iMCP.app: ${INSTALL_APP}" >&2
  exit 2
fi

COMMAND="${1:-install}"
case "${COMMAND}" in
  build|install|run|debug|logs|telemetry) ;;
  -h|--help|help)
    echo "usage: $0 [build|install|run|debug|logs|telemetry]" >&2
    exit 0
    ;;
  *)
    echo "usage: $0 [build|install|run|debug|logs|telemetry]" >&2
    exit 2
    ;;
esac

cleanup() {
  imcp_resume_relaunchers
  if [[ -n "${STAGE_ROOT}" && -d "${STAGE_ROOT}" ]]; then
    rm -rf "${STAGE_ROOT}"
  fi
}
trap cleanup EXIT

# Only an install signs, so `build` works on a Mac without a development
# certificate.
if [[ "${COMMAND}" != "build" ]]; then
  if [[ -z "${SIGN_IDENTITY}" && -d "${INSTALL_APP}" ]]; then
    installed_authority="$("${ROOT_DIR}/Scripts/verify-app-signing.sh" --print-authority "${INSTALL_APP}")"
    case "$(imcp_authority_kind "${installed_authority}")" in
      development)
        if security find-identity -v -p codesigning | grep -qF "\"${installed_authority}\""; then
          SIGN_IDENTITY="${installed_authority}"
        fi
        ;;
    esac
  fi
  # Nothing installed to match: use this Mac's first Apple Development identity.
  if [[ -z "${SIGN_IDENTITY}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/"Apple Development:/ {print $2; exit}')"
  fi

  if [[ -z "${SIGN_IDENTITY}" ]] || ! security find-identity -v -p codesigning | grep -qF "${SIGN_IDENTITY}"; then
    echo "error: code-signing identity not found: ${SIGN_IDENTITY:-none; set IMCP_SIGN_IDENTITY}" >&2
    exit 1
  fi
fi

# Build products are .app bundles. Spotlight and Launchpad treat them as
# installed copies of iMCP unless the derived-data tree is excluded.
mkdir -p "${DERIVED_DATA_PATH}"
touch "${DERIVED_DATA_PATH}/.metadata_never_index"

echo "Building iMCP"
xcodebuild -quiet -project "${ROOT_DIR}/iMCP.xcodeproj" -scheme iMCP "${IMCP_XCODEBUILD_DEBUG[@]}" build

# `build` warms the incremental build Scripts/ship.sh installs after merge, and
# catches local-Xcode-only errors, without touching the running app.
if [[ "${COMMAND}" == "build" ]]; then
  exit 0
fi

IMCP_ALLOW_ADHOC=1 "${ROOT_DIR}/Scripts/verify-app-signing.sh" "${SOURCE_APP}"

STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/imcp-install.XXXXXX")"
STAGED_APP="${STAGE_ROOT}/iMCP.app"
ditto "${SOURCE_APP}" "${STAGED_APP}"

# The build already carries the right identity when Xcode signed it with the
# development certificate. Re-signing then only costs time, and it would strip
# the embedded provisioning profile's authorization off a nested binary.
staged_authority="$("${ROOT_DIR}/Scripts/verify-app-signing.sh" --print-authority "${STAGED_APP}")"
if [[ "${staged_authority}" != "${SIGN_IDENTITY}" ]]; then
  codesign \
    --force \
    --deep \
    --sign "${SIGN_IDENTITY}" \
    --preserve-metadata=identifier,entitlements,flags,runtime \
    "${STAGED_APP}"
fi

"${ROOT_DIR}/Scripts/verify-app-signing.sh" "${STAGED_APP}"

# TCC grants bind to the app's designated code requirement. Refuse an identity
# change before replacing the installed bundle, because that would make macOS
# ask for Contacts, Photos, Reminders, Full Disk Access, and other grants again.
if [[ -d "${INSTALL_APP}" && "${IMCP_ALLOW_PERMISSION_RESET:-0}" != "1" ]]; then
  installed_requirement="$("${ROOT_DIR}/Scripts/verify-app-signing.sh" --print-requirement "${INSTALL_APP}")"
  staged_requirement="$("${ROOT_DIR}/Scripts/verify-app-signing.sh" --print-requirement "${STAGED_APP}")"
  if [[ -z "${installed_requirement}" || -z "${staged_requirement}" ]]; then
    echo "error: could not compare installed and staged code requirements" >&2
    exit 1
  fi
  if [[ "${installed_requirement}" != "${staged_requirement}" ]]; then
    echo "error: install would invalidate macOS privacy permissions" >&2
    echo "installed requirement: ${installed_requirement}" >&2
    echo "staged requirement:   ${staged_requirement}" >&2
    echo "Set IMCP_ALLOW_PERMISSION_RESET=1 only when a one-time permission reset is intended." >&2
    exit 1
  fi
fi

mkdir -p "${BACKUP_DIR}"
touch "${BACKUP_DIR}/.metadata_never_index"
BACKUP_ZIP=""

if [[ -d "${INSTALL_APP}" ]]; then
  existing_authority="$("${ROOT_DIR}/Scripts/verify-app-signing.sh" --print-authority "${INSTALL_APP}")"
  if [[ "$(imcp_authority_kind "${existing_authority}")" == "developer-id" ]]; then
    echo "warning: replacing a Developer ID install at ${INSTALL_APP} with a Debug build signed as ${SIGN_IDENTITY}" >&2
  fi
  # Zip, do not leave a bundle. A renamed .app is still an Application to Spotlight.
  BACKUP_ZIP="${BACKUP_DIR}/iMCP-$(date -u +%Y%m%dT%H%M%SZ).zip"
  echo "Backing up current app to ${BACKUP_ZIP}"
  ditto -c -k --keepParent "${INSTALL_APP}" "${BACKUP_ZIP}"
  rm -rf "${INSTALL_APP}"
fi

if ! mv "${STAGED_APP}" "${INSTALL_APP}"; then
  if [[ -n "${BACKUP_ZIP}" && -f "${BACKUP_ZIP}" && ! -d "${INSTALL_APP}" ]]; then
    ditto -x -k "${BACKUP_ZIP}" "$(dirname "${INSTALL_APP}")"
  fi
  echo "error: failed to install ${INSTALL_APP}; previous app restored when possible" >&2
  exit 1
fi

"${ROOT_DIR}/Scripts/verify-app-signing.sh" "${INSTALL_APP}"
echo "Installed verified local build: ${INSTALL_APP}"

# Finder and the Dock key their icon cache on the bundle's modification date.
# A build only changes files inside Contents, and ditto keeps the bundle's own
# date, so a new icon would keep showing the old one. The date is not part of
# the signature.
touch "${INSTALL_APP}"

# Each backup is a whole app bundle; keep only the undo for this install by
# default. The timestamped names sort oldest first.
KEEP_BACKUPS="${IMCP_KEEP_BACKUPS:-1}"
backups=("${BACKUP_DIR}"/iMCP-*.zip)
if [[ -f "${backups[0]}" ]] && ((${#backups[@]} > KEEP_BACKUPS)); then
  rm -f "${backups[@]:0:${#backups[@]}-KEEP_BACKUPS}"
fi

# Every build product is an iMCP.app too, and Launch Services offers each copy
# it knows in Open With and Launchpad. Only the installed one stays registered.
# This script's own product is kept, because Scripts/test.sh builds into the
# same tree and reuses it, and unregistered by its exact path (Spotlight does
# not index that tree, so mdfind cannot find it); copies other builds left
# (Xcode, a plain xcodebuild) are unregistered too.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "${LSREGISTER}" ]]; then
  while IFS= read -r extra_app; do
    [[ -z "${extra_app}" || "${extra_app}" == "${INSTALL_APP}" ]] && continue
    "${LSREGISTER}" -u "${extra_app}" >/dev/null 2>&1 || true
  done < <(
    /usr/bin/mdfind "kMDItemCFBundleIdentifier == \"${BUNDLE_ID}\"" 2>/dev/null || true
    find "${HOME}/Library/Developer/Xcode/DerivedData" \
      -path '*/Build/Products/*/iMCP.app' -type d -prune -print 2>/dev/null || true
  )
fi
if [[ -x "${LSREGISTER}" ]]; then
  "${LSREGISTER}" -u "${SOURCE_APP}" >/dev/null 2>&1 || true
  "${LSREGISTER}" -f "${INSTALL_APP}" >/dev/null 2>&1 || true
fi
if [[ -n "${BACKUP_ZIP}" && -f "${BACKUP_ZIP}" ]]; then
  echo "Recoverable backup: ${BACKUP_ZIP}"
fi

# Machine-specific follow-up (for example reconnecting an MCP client) lives in
# an untracked, executable Scripts/post-install.local.sh.
run_post_install_hook() {
  local hook="${ROOT_DIR}/Scripts/post-install.local.sh"
  if [[ -x "${hook}" ]]; then
    "${hook}" || echo "warning: ${hook} failed" >&2
  fi
}

relaunch_app() {
  imcp_relaunch
  imcp_wait_ready
  run_post_install_hook
}

case "${COMMAND}" in
  run)
    relaunch_app
    ;;
  debug)
    # The watchdog relaunches the installed app as soon as it exits, which
    # would start a second copy next to the one lldb runs. It stays paused
    # until lldb quits; the EXIT trap resumes it, and it relaunches the app.
    imcp_pause_relaunchers
    imcp_stop_app
    lldb -- "${APP_EXECUTABLE}"
    ;;
  logs)
    relaunch_app
    /usr/bin/log stream --info --style compact --predicate "$(imcp_log_predicate)"
    ;;
  telemetry)
    relaunch_app
    /usr/bin/log stream --info --style compact --predicate "$(imcp_log_predicate) AND subsystem == \"${BUNDLE_ID}\""
    ;;
esac
