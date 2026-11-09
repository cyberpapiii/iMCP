#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Scripts/lint.sh [--fix | --scripts]

  (none)     Check Swift formatting the way CI does
  --fix      Format Swift sources in place, then check
  --scripts  Check Scripts/: shellcheck, Python syntax, Node syntax, and
             ship.sh's merge gate against canned CI results
EOF
}

cd "$(dirname "${BASH_SOURCE[0]}")/.."

case "${1:-}" in
  "")
    swift format lint --strict --recursive .
    ;;
  --fix)
    swift format -i -r .
    swift format lint --strict --recursive .
    ;;
  --scripts)
    shellcheck Scripts/*.sh Scripts/lib/*.sh
    pycache="$(mktemp -d "${TMPDIR:-/tmp}/imcp-pycache.XXXXXX")"
    trap 'rm -rf "${pycache}"' EXIT
    PYTHONPYCACHEPREFIX="${pycache}" python3 -m py_compile Scripts/*.py
    for script in Scripts/*.mjs; do
      node --check "${script}"
    done
    Scripts/lib/ci-checks-test.sh
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
