#!/usr/bin/env bash
# Documents the missing signed Bare artifact. Does not fetch remote JS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/tool/connectivity_harness/BUNDLE.manifest"
if [[ ! -f "$MANIFEST" ]]; then
  echo "missing BUNDLE.manifest" >&2
  exit 1
fi
echo "local worklet manifest: $MANIFEST"
if [[ ! -x "${ORBITS_BARE_BIN:-}" ]]; then
  echo "blocked: signed Bare binary is not in this tree (set ORBITS_BARE_BIN)" >&2
  echo "blocked: platform signing (Apple/Android/Authenticode) is not available here" >&2
  exit 2
fi
echo "bare binary: $ORBITS_BARE_BIN"
