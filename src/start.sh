#!/usr/bin/env bash
# start.sh — entrypoint wrapper: run init, then supervise long-lived services.
set -euo pipefail

log() { echo "[start] $*"; }

CODEX_LB_SUPERVISED=1 /app/src/init.sh

pids=()

shutdown() {
  log "shutting down..."
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  wait || true
}
trap shutdown TERM INT

case "${CODEX_LB_ENABLED:-1}" in
  0|false|FALSE|no|NO)
    log "codex-lb supervisor disabled by CODEX_LB_ENABLED."
    ;;
  *)
    /app/src/codex-lb-supervisor.sh &
    pids+=("$!")
    ;;
esac

node /app/src/server.js &
pids+=("$!")

set +e
wait -n "${pids[@]}"
status=$?
set -e

shutdown
exit "$status"
