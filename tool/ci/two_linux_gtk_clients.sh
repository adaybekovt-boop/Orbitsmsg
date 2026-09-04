#!/usr/bin/env bash
# Launch two isolated Linux GTK Orbits instances (LOCAL TESTNET / localhost).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${1:-$ROOT/build/linux/x64/debug/bundle/orbits_flutter}"
EVIDENCE="${ORBITS_EVIDENCE:-/tmp/orbits-gtk-1to1}"
mkdir -p "$EVIDENCE"
if [[ ! -x "$BIN" ]]; then
  echo "missing binary $BIN" >&2
  exit 1
fi
sha256sum "$BIN" | tee "$EVIDENCE/binary.sha256"
export DISPLAY="${DISPLAY:-:1}"
export PULSE_SERVER=""
unset PULSE_RUNTIME_PATH || true

launch_one() {
  local name="$1"
  local home="$EVIDENCE/$name-home"
  rm -rf "$home"
  mkdir -p "$home" "$home/.config" "$home/.local/share" "$home/.cache" \
    "$home/Documents" "$home/Downloads"
  cat >"$home/.config/user-dirs.dirs" <<EOF
XDG_DOCUMENTS_DIR="\$HOME/Documents"
XDG_DOWNLOAD_DIR="\$HOME/Downloads"
EOF
  local log="$EVIDENCE/$name.stderr.log"
  env -u PULSE_SERVER \
    HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_DATA_HOME="$home/.local/share" \
    XDG_CACHE_HOME="$home/.cache" \
    XDG_RUNTIME_DIR="$home/runtime" \
    XDG_STATE_HOME="$home/.local/state" \
    TMPDIR="$home/tmp" \
    DISPLAY="$DISPLAY" \
    XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" \
    "$BIN" >"$EVIDENCE/$name.stdout.log" 2>"$log" &
  local pid=$!
  echo "$pid" >"$EVIDENCE/$name.pid"
  echo "$name pid=$pid home=$home"
}

mkdir -p "$EVIDENCE/alice-home/runtime" "$EVIDENCE/bob-home/runtime" \
  "$EVIDENCE/alice-home/tmp" "$EVIDENCE/bob-home/tmp"
launch_one alice
sleep 2
launch_one bob
sleep 4
echo "alice_alive=$(kill -0 "$(cat "$EVIDENCE/alice.pid")" 2>/dev/null && echo yes || echo no)"
echo "bob_alive=$(kill -0 "$(cat "$EVIDENCE/bob.pid")" 2>/dev/null && echo yes || echo no)"
echo "alice_exit=$(if kill -0 "$(cat "$EVIDENCE/alice.pid")" 2>/dev/null; then echo running; else wait "$(cat "$EVIDENCE/alice.pid")" || echo $?; fi)"
echo "--- alice stderr ---"
tail -n 40 "$EVIDENCE/alice.stderr.log" || true
echo "--- bob stderr ---"
tail -n 40 "$EVIDENCE/bob.stderr.log" || true
if grep -E 'ADM Fatal|adm_helpers|SIGABRT|Fatal' "$EVIDENCE"/*.stderr.log; then
  echo "ADM_FATAL_PRESENT"
  exit 2
fi
echo "NO_ADM_FATAL"
