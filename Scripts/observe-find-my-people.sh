#!/usr/bin/env bash
set -euo pipefail

DURATION="${1:-60}"
INTERVAL="${2:-2}"
[[ "${DURATION}" =~ ^[0-9]+$ && "${DURATION}" -ge 1 && "${DURATION}" -le 900 ]] || exit 2
[[ "${INTERVAL}" =~ ^[0-9]+$ && "${INTERVAL}" -ge 1 && "${INTERVAL}" -le 60 ]] || exit 2

DARWIN_DIR="$(getconf DARWIN_USER_DIR 2>/dev/null || true)"
CONFINEMENT="${DARWIN_DIR}com.apple.findmy.findmylocateagent/LocalStorage.db"
GROUP_CONTAINER="${HOME}/Library/Group Containers/group.com.apple.findmy.findmylocateagent/Library/Application Support/LocalStorage.db"

metadata() {
  local label="$1" path="$2"
  local database_size=0 database_mtime=0 wal_size=0 wal_mtime=0
  if [[ -f "${path}" && ! -L "${path}" ]]; then
    database_size="$(stat -f '%z' "${path}")"
    database_mtime="$(stat -f '%m' "${path}")"
  fi
  if [[ -f "${path}-wal" && ! -L "${path}-wal" ]]; then
    wal_size="$(stat -f '%z' "${path}-wal")"
    wal_mtime="$(stat -f '%m' "${path}-wal")"
  fi
  printf '{"path_class":"%s","database_size":%s,"database_mtime":%s,"wal_size":%s,"wal_mtime":%s}\n' \
    "${label}" "${database_size}" "${database_mtime}" "${wal_size}" "${wal_mtime}"
}

echo '{"observer":"find-my-people-metadata-v1","payload_blind":true}'
elapsed=0
while [[ "${elapsed}" -lt "${DURATION}" ]]; do
  metadata confinement "${CONFINEMENT}"
  metadata group-container "${GROUP_CONTAINER}"
  sleep "${INTERVAL}"
  elapsed=$((elapsed + INTERVAL))
done

# Count recent process log events without rendering any message payload.
events="$(/usr/bin/log show --last "${DURATION}s" --style compact \
  --predicate 'process == "findmylocateagent"' 2>/dev/null | /usr/bin/awk 'NR > 1 {count++} END {print count+0}')"
printf '{"findmylocateagent_log_event_count":%s}\n' "${events}"
