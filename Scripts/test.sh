#!/usr/bin/env bash
set -euo pipefail

# Runs both test suites the way they have to be run on this machine: with the
# installed app stopped.
#
# The always-on watchdog relaunches the installed app, and a running installed
# app makes the app suite fail to launch its test bundle with "LaunchServices
# launcher has returned an error" -- a failure that says nothing about the
# code. This pauses everything that would relaunch the app, stops the app, and
# puts both back afterwards, whether the tests passed, failed, or were
# interrupted. On a machine without an install (CI) there is nothing to stop.

# shellcheck source=lib/imcp.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/imcp.sh"

usage() {
  cat <<'EOF'
Usage: Scripts/test.sh [options] [-- xcodebuild arguments...]

Options:
      --app-only         Run only the app suite
      --cli-only         Run only the CLI suite
      --only SPEC        Pass -only-testing:SPEC (repeatable, implies --app-only)
      --no-build         Skip build-for-testing and run the existing products
  -h, --help             Show help

xcodebuild arguments (for example build-setting overrides) go to every
xcodebuild call, builds included.
EOF
}

RUN_APP="1"
RUN_CLI="1"
BUILD="1"
only_specs=()
passthrough=()

while (($#)); do
  case "$1" in
    --app-only) RUN_CLI="0"; shift ;;
    --cli-only) RUN_APP="0"; shift ;;
    --only)
      only_specs+=("${2:?--only needs a test specifier}")
      RUN_CLI="0"
      shift 2
      ;;
    --no-build) BUILD="0"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; passthrough+=("$@"); break ;;
    *) passthrough+=("$1"); shift ;;
  esac
done

if [[ "${RUN_APP}" == "0" && "${RUN_CLI}" == "0" ]]; then
  echo "error: no suite selected; --cli-only cannot be combined with --app-only or --only" >&2
  exit 2
fi

cd "${IMCP_ROOT_DIR}"

app_was_running="0"

restore_app() {
  imcp_resume_relaunchers
  if [[ "${app_was_running}" == "1" ]]; then
    imcp_open_app >/dev/null 2>&1 || true
  fi
}

# Armed before anything is paused. An interrupt between the first SIGSTOP and a
# later trap would leave the app dead under a frozen watchdog.
trap restore_app EXIT

if [[ "${RUN_APP}" == "1" ]]; then
  imcp_pause_relaunchers
  if [[ -n "$(imcp_app_pids)" ]]; then
    app_was_running="1"
  fi
  if ! imcp_stop_app; then
    echo "error: the installed app must quit before the app tests" >&2
    exit 1
  fi
fi

common=(
  "${IMCP_XCODEBUILD_DEBUG[@]}"
  ${passthrough[@]+"${passthrough[@]}"}
)

# A test that hangs fails after a minute (XCTest counts whole minutes), and
# the run goes on with the next test, instead of the hang using up the CI
# job's timeout. A test cannot ask for more time than the same minute.
test_timeouts=(
  -test-timeouts-enabled YES
  -default-test-execution-time-allowance 60
  -maximum-test-execution-time-allowance 60
)

if [[ "${BUILD}" == "1" ]]; then
  # Building once for both schemes is what keeps the second suite from
  # rebuilding what the first just built.
  [[ "${RUN_CLI}" == "1" ]] \
    && xcodebuild -quiet build-for-testing -scheme imcp-serverTests "${common[@]}"
  [[ "${RUN_APP}" == "1" ]] \
    && xcodebuild -quiet build-for-testing -scheme iMCP "${common[@]}"
fi

if [[ "${RUN_CLI}" == "1" ]]; then
  xcodebuild test-without-building -scheme imcp-serverTests "${common[@]}" "${test_timeouts[@]}"
fi

if [[ "${RUN_APP}" == "1" ]]; then
  only_arguments=()
  for spec in ${only_specs[@]+"${only_specs[@]}"}; do
    only_arguments+=("-only-testing:${spec}")
  done
  xcodebuild test-without-building -scheme iMCP "${common[@]}" "${test_timeouts[@]}" \
    ${only_arguments[@]+"${only_arguments[@]}"}
fi
