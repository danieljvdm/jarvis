#!/usr/bin/env bash
# Keep codex-lb available for OpenClaw/Codex model traffic.
set -euo pipefail

log() { echo "[codex-lb] $*"; }

CODEX_LB_DATA_DIR="${CODEX_LB_DATA_DIR:-/data/.codex-lb}"
CODEX_LB_HOST="${CODEX_LB_HOST:-127.0.0.1}"
CODEX_LB_PORT="${CODEX_LB_PORT:-2455}"
CODEX_LB_LOG="${CODEX_LB_LOG:-/data/.local/state/codex-lb.log}"
CODEX_LB_READY_URL="${CODEX_LB_READY_URL:-http://${CODEX_LB_HOST}:${CODEX_LB_PORT}/v1/models}"
CODEX_LB_RESTART_DELAY="${CODEX_LB_RESTART_DELAY:-5}"
CODEX_LB_MISSING_STORE_DELAY="${CODEX_LB_MISSING_STORE_DELAY:-60}"

child_pid=""

stop_child() {
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
}

shutdown() {
  log "stopping supervisor..."
  stop_child
  exit 0
}
trap shutdown TERM INT

mkdir -p "$CODEX_LB_DATA_DIR" "$(dirname "$CODEX_LB_LOG")"

if ! command -v uvx >/dev/null 2>&1; then
  log "uvx is not installed; supervisor exiting."
  exit 0
fi

while true; do
  if [ ! -f "$CODEX_LB_DATA_DIR/store.db" ]; then
    log "no store.db in ${CODEX_LB_DATA_DIR}; waiting for seeded sessions."
    sleep "$CODEX_LB_MISSING_STORE_DELAY"
    continue
  fi

  if curl -fsS "$CODEX_LB_READY_URL" >/dev/null 2>&1; then
    sleep 15
    continue
  fi

  log "starting on ${CODEX_LB_HOST}:${CODEX_LB_PORT}..."
  (
    cd /data
    HOME=/data XDG_CONFIG_HOME=/data/.config XDG_CACHE_HOME=/data/.cache \
      uvx codex-lb --host "$CODEX_LB_HOST" --port "$CODEX_LB_PORT" \
      >> "$CODEX_LB_LOG" 2>&1
  ) &
  child_pid="$!"

  ready=0
  for _ in $(seq 1 90); do
    if curl -fsS "$CODEX_LB_READY_URL" >/dev/null 2>&1; then
      log "ready at ${CODEX_LB_READY_URL}"
      ready=1
      break
    fi
    if ! kill -0 "$child_pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  if [ "$ready" != "1" ]; then
    log "not ready yet; continuing to watch pid ${child_pid}"
  fi

  set +e
  wait "$child_pid"
  status=$?
  set -e
  child_pid=""
  log "exited with status ${status}; restarting in ${CODEX_LB_RESTART_DELAY}s"
  sleep "$CODEX_LB_RESTART_DELAY"
done
