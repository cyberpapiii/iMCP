#!/usr/bin/env bash
# Checks ship.sh's merge gate against canned `gh pr checks --json name,bucket`
# output. Offline; run by `Scripts/lint.sh --scripts`.
set -euo pipefail

# shellcheck source=ci-checks.sh
source "$(dirname "${BASH_SOURCE[0]}")/ci-checks.sh"

failures=0

# expect allow|block NAME JSON
expect() {
  local want="$1" name="$2" json="$3" got
  if ci_checks_allow_merge <<<"${json}" 2>/dev/null; then got="allow"; else got="block"; fi
  if [[ "${got}" == "${want}" ]]; then
    echo "ok: ${name}"
  else
    echo "FAIL: ${name}: expected ${want}, got ${got}" >&2
    failures=$((failures + 1))
  fi
}

pinned='{"name":"Build and test on macOS 26 with pinned Xcode","bucket":"pass"}'
release='{"name":"Release build on macOS 26 with pinned Xcode","bucket":"pass"}'

expect allow "every check passed" \
  "[${pinned},${release},{\"name\":\"Build and test on macOS 27 with Xcode 27 preview (experimental)\",\"bucket\":\"pass\"}]"
expect allow "a cancelled experimental check" \
  "[${pinned},${release},{\"name\":\"Build and test on macOS 27 with Xcode 27 preview (experimental)\",\"bucket\":\"cancel\"}]"
expect allow "a failed experimental check" \
  "[${pinned},${release},{\"name\":\"Build and test on macOS 27 with Xcode 27 preview (experimental)\",\"bucket\":\"fail\"}]"
expect block "a cancelled required check" \
  "[{\"name\":\"Build and test on macOS 26 with pinned Xcode\",\"bucket\":\"cancel\"},${release}]"
expect block "a skipped required check" \
  "[${pinned},{\"name\":\"Release build on macOS 26 with pinned Xcode\",\"bucket\":\"skipping\"}]"
expect block "a pending required check" \
  "[${pinned},{\"name\":\"Lint scripts\",\"bucket\":\"pending\"}]"
expect block "the marker only counts as a suffix" \
  "[{\"name\":\"Build (experimental) on macOS 26\",\"bucket\":\"cancel\"},${release}]"

# The suffix is only a marker if ci.yml writes it.
workflow="$(dirname "${BASH_SOURCE[0]}")/../../.github/workflows/ci.yml"
if grep -qF "'${CI_EXPERIMENTAL_SUFFIX}'" "${workflow}"; then
  echo "ok: ci.yml marks experimental jobs with '${CI_EXPERIMENTAL_SUFFIX}'"
else
  echo "FAIL: ci.yml does not append '${CI_EXPERIMENTAL_SUFFIX}' to experimental job names" >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  exit 1
fi
