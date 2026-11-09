#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/ci-checks.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/ci-checks.sh"

ROOT_DIR="$(git rev-parse --show-toplevel)"
ORIGINAL_ROOT="${ROOT_DIR}"
cd "${ROOT_DIR}"
REMOTE="${IMCP_SHIP_REMOTE:-origin}"
BASE_BRANCH="${IMCP_SHIP_BASE_BRANCH:-main}"
COMMIT_MESSAGE=""
PR_TITLE=""
PR_BODY=""
RELEASE_VERSION=""
INSTALL="1"
KEEP_BRANCH="0"
LOCAL_TESTS="0"
ALLOW_RECORD_DELETES="0"

usage() {
  cat <<'EOF'
Usage: Scripts/ship.sh [options]

Format, build, commit, push, open a PR, merge it after CI, install the exact
merged main build, then remove the merged branch, temporary worktree, and any
other local branch whose PR already merged.

CI runs both test suites on every PR, so by default the installed app keeps
running until the merged build replaces it. Pass --local-tests to also run
Scripts/test.sh before pushing.

Options:
  -m, --message TEXT     Commit message (default: "chore: ship development changes")
  -t, --title TEXT       PR title (default: commit subject line)
  -b, --body TEXT        PR body (default: commit message body)
      --local-tests      Run both test suites locally before pushing
      --allow-record-deletes
                         Allow deleting files under plans/, docs/plans/, or
                         docs/ideation/ (planning records; see AGENTS.md)
      --release VERSION Bump version in the PR, then notarize and publish release
      --no-install       Skip local build/install after merge
      --keep-branch      Keep local merged branch
  -h, --help             Show help

New files must be staged with git add first; untracked files stop the run.
Re-run the same command to resume after a CI failure (re-run the failed check
on GitHub first if there is no new commit).

Release environment:
  KEYCHAIN_PROFILE       notarytool Keychain profile (required with --release)
  Other release.sh signing variables remain supported.
EOF
}

while (($#)); do
  case "$1" in
    -m|--message)
      COMMIT_MESSAGE="${2:?--message needs a value}"
      shift 2
      ;;
    -t|--title)
      PR_TITLE="${2:?--title needs a value}"
      shift 2
      ;;
    -b|--body)
      PR_BODY="${2:?--body needs a value}"
      shift 2
      ;;
    --local-tests)
      LOCAL_TESTS="1"
      shift
      ;;
    --allow-record-deletes)
      ALLOW_RECORD_DELETES="1"
      shift
      ;;
    --release)
      RELEASE_VERSION="${2:?--release needs a version}"
      shift 2
      ;;
    --no-install)
      INSTALL="0"
      shift
      ;;
    --keep-branch)
      KEEP_BRANCH="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

COMMIT_MESSAGE="${COMMIT_MESSAGE:-chore: ship development changes}"
# A commit message carries a body; a PR title is one line and GitHub rejects it
# past 256 characters. Taking the subject line keeps a long, explanatory commit
# from failing the run after the branch has already been pushed.
PR_TITLE="${PR_TITLE:-$(printf '%s\n' "${COMMIT_MESSAGE}" | head -n 1)}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command missing: $1" >&2
    exit 1
  fi
}

for command in git gh xcodebuild swift; do
  require_command "${command}"
done

if [[ -n "${RELEASE_VERSION}" && -z "${KEYCHAIN_PROFILE:-}" ]]; then
  echo "error: KEYCHAIN_PROFILE is required with --release" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "error: GitHub CLI is not authenticated" >&2
  exit 1
fi

# release.sh owns the rule: a GitHub remote, and never upstream mattt/iMCP.
repo="$(RELEASE_REMOTE="${REMOTE}" "${ROOT_DIR}/Scripts/release.sh" repo)"

current_branch="$(git branch --show-current)"
if [[ -z "${current_branch}" ]]; then
  echo "error: detached HEAD is not supported" >&2
  exit 1
fi
started_on_base="0"

untracked="$(git ls-files --others --exclude-standard)"
if [[ -n "${untracked}" ]]; then
  echo "error: untracked files. git add the ones that belong in this change; remove or ignore the rest:" >&2
  printf '%s\n' "${untracked}" | sed 's/^/  /' >&2
  exit 1
fi

git fetch "${REMOTE}" "${BASE_BRANCH}"

# Commits on this branch that the base lacks are a run to resume: an earlier
# attempt committed and pushed, then stopped at CI.
if git diff --quiet HEAD -- \
  && [[ "$(git rev-list --count "${REMOTE}/${BASE_BRANCH}..HEAD")" == "0" ]]; then
  echo "error: nothing to ship" >&2
  exit 1
fi

if [[ "${current_branch}" == "${BASE_BRANCH}" ]]; then
  started_on_base="1"
  timestamp="$(date -u +%Y%m%d-%H%M%S)"
  current_branch="ship/${timestamp}"
  git switch -c "${current_branch}"
fi

if [[ -n "${RELEASE_VERSION}" ]]; then
  VERSION="${RELEASE_VERSION}" Scripts/release.sh bump
fi

Scripts/lint.sh --fix
git add -u

# Planning tools find their own history in these folders; cleanup passes have
# deleted them as dead docs before.
if [[ "${ALLOW_RECORD_DELETES}" != "1" ]]; then
  deleted_records="$(git diff --cached --diff-filter=D --name-only \
    "$(git merge-base "${REMOTE}/${BASE_BRANCH}" HEAD)" -- plans docs/plans docs/ideation)"
  if [[ -n "${deleted_records}" ]]; then
    echo "error: this change deletes planning records (see AGENTS.md Records):" >&2
    printf '%s\n' "${deleted_records}" | sed 's/^/  /' >&2
    echo "Restore them, or pass --allow-record-deletes if the deletion is intended." >&2
    exit 1
  fi
fi

# Compiles with this Mac's Xcode, which can be newer than CI's, and warms the
# incremental build the post-merge install reuses. The running app is untouched.
if [[ "${INSTALL}" == "1" ]]; then
  "${ROOT_DIR}/Scripts/install-local.sh" build
fi

if [[ "${LOCAL_TESTS}" == "1" ]]; then
  "${ROOT_DIR}/Scripts/test.sh"
fi

if git diff --cached --quiet; then
  echo "No new changes to commit; resuming with the commits already on ${current_branch}"
else
  git commit -m "${COMMIT_MESSAGE}"
fi
git push --set-upstream "${REMOTE}" "${current_branch}"

pr_url="$(gh pr list --repo "${repo}" --head "${current_branch}" --state open --json url --jq '.[0].url // empty')"
if [[ -z "${pr_url}" ]]; then
  body_arguments=(--fill)
  if [[ -n "${PR_BODY}" ]]; then
    body_arguments=(--body "${PR_BODY}")
  fi
  pr_url="$(gh pr create --repo "${repo}" --base "${BASE_BRANCH}" --head "${current_branch}" \
    --title "${PR_TITLE}" "${body_arguments[@]}")"
fi
echo "PR: ${pr_url}"

# GitHub can briefly report no checks immediately after PR creation.
checks_seen="0"
head_sha="$(git rev-parse HEAD)"
for _ in {1..150}; do
  check_count="$(gh pr view "${pr_url}" --repo "${repo}" --json headRefOid,statusCheckRollup \
    --jq "select(.headRefOid == \"${head_sha}\") | .statusCheckRollup | length")"
  if [[ "${check_count:-0}" -gt 0 ]]; then
    checks_seen="1"
    break
  fi
  sleep 2
done
if [[ "${checks_seen}" != "1" ]]; then
  echo "error: CI checks did not appear for ${pr_url}" >&2
  exit 1
fi

# Waits for every check, not only until the first failure: an experimental
# job may fail without blocking, and the gate below decides. Its exit status
# is not the verdict, because a cancelled or skipped job (for example one that
# hit its timeout) does not make it fail.
gh pr checks "${pr_url}" --repo "${repo}" --watch || true
if ! gh pr checks "${pr_url}" --repo "${repo}" --json name,bucket | ci_checks_allow_merge; then
  echo "error: not merging ${pr_url}" >&2
  exit 1
fi
gh pr merge "${pr_url}" --repo "${repo}" --merge --delete-branch

if [[ "${started_on_base}" == "1" ]]; then
  git switch "${BASE_BRANCH}"
  main_root="${ORIGINAL_ROOT}"
else
  main_root="$(git worktree list --porcelain | awk -v branch="refs/heads/${BASE_BRANCH}" '
    /^worktree / { path = substr($0, 10) }
    $0 == "branch " branch { print path; exit }
  ')"
fi

if [[ -z "${main_root}" ]]; then
  # A resumed run may start from a feature branch in the primary checkout after
  # an earlier pre-merge failure. Once GitHub merged it, this clean checkout can
  # safely become the main worktree again.
  if [[ "${ORIGINAL_ROOT}" == "$(git rev-parse --show-toplevel)" ]] && git diff --quiet HEAD --; then
    git switch "${BASE_BRANCH}"
    main_root="${ORIGINAL_ROOT}"
  else
    echo "error: no worktree has ${BASE_BRANCH} checked out; PR merged, local install not started" >&2
    exit 1
  fi
fi

git -C "${main_root}" pull --ff-only "${REMOTE}" "${BASE_BRANCH}"
merged_sha="$(gh pr view "${pr_url}" --repo "${repo}" --json mergeCommit --jq .mergeCommit.oid)"
local_sha="$(git -C "${main_root}" rev-parse HEAD)"
if [[ "${merged_sha}" != "${local_sha}" ]]; then
  echo "error: local ${BASE_BRANCH} ${local_sha} does not match merged PR ${merged_sha}" >&2
  exit 1
fi

if [[ -n "${RELEASE_VERSION}" ]]; then
  (
    cd "${main_root}"
    VERSION="${RELEASE_VERSION}" RELEASE_REMOTE="${REMOTE}" Scripts/release.sh publish
  )
fi

if [[ "${INSTALL}" == "1" ]]; then
  (
    cd "${main_root}"
    Scripts/install-local.sh run
  )
fi

if [[ "${ORIGINAL_ROOT}" != "${main_root}" ]]; then
  cd "${main_root}"
  # Refused for the primary checkout and for a worktree with untracked files.
  # The ship already succeeded; say so and carry on.
  git worktree remove "${ORIGINAL_ROOT}" \
    || echo "warning: kept ${ORIGINAL_ROOT}; remove it by hand if it is no longer needed" >&2
  git worktree prune
fi

if [[ "${KEEP_BRANCH}" != "1" ]]; then
  git -C "${main_root}" branch -d "${current_branch}" >/dev/null 2>&1 || true
  # Branches from earlier merged PRs: GitHub deleted the remote, `-d` keeps
  # anything with unmerged commits.
  git -C "${main_root}" fetch --prune --quiet "${REMOTE}" || true
  git -C "${main_root}" for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads \
    | awk '$2 == "[gone]" { print $1 }' \
    | while IFS= read -r gone_branch; do
      git -C "${main_root}" branch -d "${gone_branch}" >/dev/null 2>&1 \
        && echo "Removed merged branch ${gone_branch}"
    done
  git -C "${main_root}" worktree prune
fi

echo "Shipped ${merged_sha}"
echo "Installed: $([[ "${INSTALL}" == "1" ]] && echo yes || echo no)"
echo "Released: ${RELEASE_VERSION:-no}"
