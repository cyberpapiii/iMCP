# shellcheck shell=bash disable=SC2034 # the variables are read by the scripts that source this file
# Sourced by the scripts in Scripts/, never run. Where iMCP is installed, which
# processes belong to that install, and how to stop and start them. Every
# function writes its diagnostics to stderr, so a caller's stdout stays its own.
#
# Nothing here calls launchctl. The always-on watchdog is paused, resumed, or
# killed (launchd's KeepAlive restarts it); booting it out unregisters the login
# item, and only the user can approve it again.

IMCP_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_APP="${IMCP_INSTALL_APP:-/Applications/iMCP.app}"
APP_EXECUTABLE="${INSTALL_APP}/Contents/MacOS/iMCP"
CLI_EXECUTABLE="${INSTALL_APP}/Contents/MacOS/imcp-server"
WATCHDOG_EXECUTABLE="${INSTALL_APP}/Contents/MacOS/iMCPAlwaysOn"
BUNDLE_ID="co.dododo.iMCP"
APP_SUPPORT_DIR="${HOME}/Library/Application Support/iMCP"
ENDPOINT_FILE="${APP_SUPPORT_DIR}/listener-endpoint.json"
# install-local.sh and test.sh build into the same tree with the same flags,
# so a local loop compiles once. Debug signs with the development identity and
# an automatically managed profile, which is what puts the keychain access
# group in the signature; the profile is minted on demand, so provisioning
# updates have to be allowed.
DERIVED_DATA_PATH="${IMCP_DERIVED_DATA_PATH:-${IMCP_ROOT_DIR}/.build/DerivedData}"
IMCP_XCODEBUILD_DEBUG=(
  -configuration Debug
  -destination "platform=macOS"
  -derivedDataPath "${DERIVED_DATA_PATH}"
  -allowProvisioningUpdates
)

# Prints the pid of every process running exactly this executable. The name
# only picks candidates: the XCTest host and Xcode-run builds are also called
# iMCP, and launchd starts the watchdog with the relative argv
# `Contents/MacOS/iMCPAlwaysOn`, so neither the name nor `ps` says which bundle
# a process came from. The executable's text mapping does, and lsof still
# reports its path after install-local.sh has replaced the bundle on disk.
imcp_pids_of() {
  local executable="$1" directory pid path
  directory="$(dirname "${executable}")"
  if [[ -d "${directory}" ]]; then
    executable="$(cd "${directory}" && pwd -P)/$(basename "${executable}")"
  fi
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    path="$(/usr/sbin/lsof -a -p "${pid}" -d txt -Fn 2>/dev/null | awk '/^n/ { print substr($0, 2); exit }')"
    [[ "${path}" == "${executable}" ]] && printf '%s\n' "${pid}"
  done < <(/usr/bin/pgrep -x "$(basename "${executable}")" 2>/dev/null || true)
  return 0
}

imcp_app_pids() { imcp_pids_of "${APP_EXECUTABLE}"; }
imcp_cli_pids() { imcp_pids_of "${CLI_EXECUTABLE}"; }
imcp_watchdog_pids() { imcp_pids_of "${WATCHDOG_EXECUTABLE}"; }

IMCP_PAUSED_PIDS=()

# Freezes everything that would relaunch the installed app: the watchdog, and
# every installed imcp-server, which reopens the app when it loses it (or dies
# and is respawned by its MCP client, which reopens it the same way). A stopped
# process cannot exit, so nothing respawns it. Arm imcp_resume_relaunchers in an
# EXIT trap before calling this.
imcp_pause_relaunchers() {
  local pid
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    IMCP_PAUSED_PIDS+=("${pid}")
    # A pid that exited since it was listed needs no pausing. One that is
    # still there and would not stop would relaunch the app.
    if ! kill -STOP "${pid}" 2>/dev/null && kill -0 "${pid}" 2>/dev/null; then
      echo "error: could not pause pid ${pid}" >&2
      return 1
    fi
  done < <(imcp_watchdog_pids; imcp_cli_pids)
}

imcp_resume_relaunchers() {
  local pid
  # An empty array expansion under `set -u` would abort an EXIT trap before it
  # resumes anything.
  for pid in ${IMCP_PAUSED_PIDS[@]+"${IMCP_PAUSED_PIDS[@]}"}; do
    kill -CONT "${pid}" >/dev/null 2>&1 || true
  done
  IMCP_PAUSED_PIDS=()
}

imcp_stop_app() {
  local pids pid alive
  pids="$(imcp_app_pids)"
  [[ -n "${pids}" ]] || return 0
  for pid in ${pids}; do
    kill "${pid}" >/dev/null 2>&1 || true
  done
  for _ in {1..50}; do
    alive="0"
    for pid in ${pids}; do
      kill -0 "${pid}" 2>/dev/null && alive="1"
    done
    [[ "${alive}" == "1" ]] || return 0
    sleep 0.2
  done
  echo "error: ${INSTALL_APP} did not quit" >&2
  return 1
}

imcp_open_app() {
  [[ -n "$(imcp_app_pids)" ]] && return 0
  /usr/bin/open "${INSTALL_APP}" || [[ -n "$(imcp_app_pids)" ]]
}

# Restarts the installed app from what is on disk now. The watchdog keeps
# executing the binary it started from and relaunches the app the moment it
# exits; an `open` racing that relaunch fails with -600. So the watchdog is
# killed (launchd's KeepAlive brings it back on the new bundle), the old app is
# stopped, and the new watchdog starts the new app. Without a watchdog the app
# is opened directly.
imcp_relaunch() {
  local watchdog_pids pid
  watchdog_pids="$(imcp_watchdog_pids)"
  if [[ -z "${watchdog_pids}" ]]; then
    imcp_stop_app || return 1
    imcp_open_app
    return
  fi
  for pid in ${watchdog_pids}; do
    kill "${pid}" >/dev/null 2>&1 || true
  done
  imcp_stop_app || return 1
  for _ in {1..30}; do
    [[ -n "$(imcp_app_pids)" ]] && return 0
    sleep 0.5
  done
  imcp_open_app
}

# True once the running installed app has published its listener: the endpoint
# file names the pid of a live installed app. A file left by an earlier launch
# names a pid that is gone, so it does not count.
imcp_is_ready() {
  local pids endpoint_pid
  pids="$(imcp_app_pids)"
  [[ -n "${pids}" && -f "${ENDPOINT_FILE}" ]] || return 1
  endpoint_pid="$(/usr/bin/plutil -extract pid raw -o - "${ENDPOINT_FILE}" 2>/dev/null || true)"
  [[ -n "${endpoint_pid}" ]] && grep -qx "${endpoint_pid}" <<<"${pids}"
}

# Waits up to $1 seconds (default 30) for imcp_is_ready.
imcp_wait_ready() {
  local attempts=$(( ${1:-30} * 2 ))
  while ((attempts-- > 0)); do
    imcp_is_ready && return 0
    sleep 0.5
  done
  if [[ -z "$(imcp_app_pids)" ]]; then
    echo "error: ${INSTALL_APP} is not running" >&2
  else
    echo "error: ${INSTALL_APP} is running but has not published its listener (${ENDPOINT_FILE}); is iMCP turned on?" >&2
  fi
  return 1
}

# Unified-log predicate for the processes of the installed bundle only. The
# XCTest host is also a process named iMCP.
imcp_log_predicate() {
  printf 'processImagePath BEGINSWITH "%s/"' "${INSTALL_APP}"
}

# What a signing authority means for an install. TCC grants and file-keychain
# ACLs bind to the signing identity, so only a stable one keeps them across
# rebuilds:
#   development   Apple Development; the profile-backed local default
#   developer-id  a notarized public release
#   adhoc         no identity: every rebuild is a stranger to macOS
#   other         anything else
imcp_authority_kind() {
  case "$1" in
    "") echo adhoc ;;
    "Apple Development:"*) echo development ;;
    "Developer ID Application:"*) echo developer-id ;;
    *) echo other ;;
  esac
}
