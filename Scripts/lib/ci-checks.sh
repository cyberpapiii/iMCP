# shellcheck shell=bash
# Sourced by ship.sh and Scripts/lib/ci-checks-test.sh, never run. Decides
# from a PR's CI checks whether ship.sh may merge it.

# .github/workflows/ci.yml appends this to the name of every matrix entry it
# marks `experimental` (and so `continue-on-error`). A check's name is all
# `gh pr checks` reports about it, so the name is how the gate tells a job
# that may fail from one that must pass.
CI_EXPERIMENTAL_SUFFIX=" (experimental)"

# Reads `gh pr checks --json name,bucket` on stdin. Every check must be in the
# `pass` bucket; a cancelled, skipped, failed, or pending one blocks the merge,
# except an experimental one, which is printed as a warning instead. Prints
# what did not pass to stderr and returns 1 when the merge is blocked.
ci_checks_allow_merge() {
  local checks blocking experimental
  checks="$(cat)"
  experimental="$(jq -r --arg suffix "${CI_EXPERIMENTAL_SUFFIX}" \
    '.[] | select(.bucket != "pass" and (.name | endswith($suffix))) | "\(.name): \(.bucket)"' \
    <<<"${checks}")"
  blocking="$(jq -r --arg suffix "${CI_EXPERIMENTAL_SUFFIX}" \
    '.[] | select(.bucket != "pass" and (.name | endswith($suffix) | not)) | "\(.name): \(.bucket)"' \
    <<<"${checks}")"
  if [[ -n "${experimental}" ]]; then
    echo "warning: an experimental CI check did not pass; it does not block the merge" >&2
    echo "${experimental}" >&2
  fi
  if [[ -n "${blocking}" ]]; then
    echo "error: not every required CI check passed" >&2
    echo "${blocking}" >&2
    return 1
  fi
}
