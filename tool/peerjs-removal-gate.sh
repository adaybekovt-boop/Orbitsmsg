#!/usr/bin/env bash
# Phase 14 removal checklist. Fails closed while prerequisites are unmet.
# Does not delete PeerJS or start the support window.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "peerjs-removal-gate: $*" >&2; exit 1; }

if ! grep -q 'kPeerjsSupportWindowOpen = true' "$ROOT/lib/transport/peerjs_window.dart"; then
  fail "support window flag changed; do not remove PeerJS from this tree"
fi
if ! grep -q "kPeerjsIsolationMode = 'default-live'" "$ROOT/lib/transport/peerjs_window.dart"; then
  fail "isolation mode is not default-live"
fi
if ! grep -q 'kCompletedMigrationPhase = 0' "$ROOT/lib/transport/layers.dart"; then
  fail "migration phase is not 0"
fi
if ! grep -q 'hyperswarmRollout = HyperswarmRollout.off' "$ROOT/lib/core/feature_flags.dart"; then
  fail "Hyperswarm rollout default is not off"
fi
if [[ "${ORBITS_PEERJS_FLEET_READY:-}" != "1" ]]; then
  fail "mailbox/fleet prerequisite unmet (ORBITS_PEERJS_FLEET_READY)"
fi
if [[ "${ORBITS_PEERJS_ADOPTION_MET:-}" != "1" ]]; then
  fail "adoption threshold prerequisite unmet (ORBITS_PEERJS_ADOPTION_MET)"
fi
if [[ "${ORBITS_PEERJS_WINDOW_CLOSED:-}" != "1" ]]; then
  fail "support window has not been closed in writing"
fi
echo "peerjs-removal-gate: all prerequisites set (still do not delete from CI)"
