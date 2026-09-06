#!/usr/bin/env bash
# LOCAL TESTNET PeerJS signaling for two localhost Orbits clients.
#
# Production 1:1 still uses public *.peerjs.com. This script is an explicit
# pin: it binds loopback only and never falls back to the cloud.
#
# Usage:
#   bash tool/local-peerjs-signaling.sh
# Then launch both GTK clients with:
#   export ORBITS_PEERJS_HOST=127.0.0.1
#   export ORBITS_PEERJS_PORT=9000
#   export ORBITS_PEERJS_SECURE=false
#
# Rooms keep their own embedded signaling server (random key, not 'peerjs').
# 1:1 clients speak key=peerjs, so this uses `npx peer` instead of the room
# host — do not weaken the room key forbid-list to reuse that path.
set -euo pipefail
HOST="${ORBITS_PEERJS_HOST:-127.0.0.1}"
PORT="${ORBITS_PEERJS_PORT:-9000}"
LOG="${ORBITS_PEERJS_SIGNALING_LOG:-/tmp/orbits-peerjs-signaling.log}"
PID_FILE="${ORBITS_PEERJS_SIGNALING_PID:-/tmp/orbits-peerjs-signaling.pid}"

if [[ "$HOST" != "127.0.0.1" && "$HOST" != "localhost" && "$HOST" != "::1" ]]; then
  echo "local-peerjs-signaling: refuse non-loopback bind ($HOST)" >&2
  exit 1
fi

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "already running pid=$(cat "$PID_FILE") $HOST:$PORT"
  exit 0
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "local-peerjs-signaling: npx is required to start peerjs-server" >&2
  exit 1
fi

# peerjs-server listens on --port (required) and --host.
npx --yes peer -p "$PORT" -H "$HOST" >"$LOG" 2>&1 &
echo $! >"$PID_FILE"
echo "started pid=$! $HOST:$PORT log=$LOG"

ready=0
for _ in $(seq 1 50); do
  if (echo >/dev/tcp/"$HOST"/"$PORT") >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
if [[ "$ready" != 1 ]]; then
  echo "local-peerjs-signaling: $HOST:$PORT never became ready" >&2
  echo "--- log ---" >&2
  tail -n 40 "$LOG" >&2 || true
  exit 1
fi
echo "ready $HOST:$PORT"
