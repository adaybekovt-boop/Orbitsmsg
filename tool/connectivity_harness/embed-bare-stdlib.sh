#!/usr/bin/env bash
# Copy the *local* bare-* stdlib zip into federated plugin native dirs.
# NEVER downloads. Dart/Flutter must not invoke this at runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tool/connectivity_harness/bare_stdlib.zip"
if [[ ! -f "$SRC" ]]; then
  echo "no local zip at $SRC (run pack-bare-stdlib.sh first)" >&2
  exit 1
fi

dests=(
  "$ROOT/packages/orbits_transport_linux/linux/bare_stdlib.zip"
  "$ROOT/packages/orbits_transport_windows/windows/bare_stdlib.zip"
  "$ROOT/packages/orbits_transport_macos/macos/bare_stdlib.zip"
  "$ROOT/packages/orbits_transport_ios/ios/bare_stdlib.zip"
  "$ROOT/packages/orbits_transport_android/android/src/main/assets/bare_stdlib.zip"
)
for dest in "${dests[@]}"; do
  mkdir -p "$(dirname "$dest")"
  cp -f "$SRC" "$dest"
  echo "embedded $SRC -> $dest"
done
echo "kBareBinaryShipped stays false until every OS slot is in the app bundle"
