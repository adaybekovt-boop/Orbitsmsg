#!/usr/bin/env bash
# Copy a *local* Bare slot into federated plugin native dirs.
# NEVER downloads. Dart/Flutter must not invoke this at runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SLOT="${1:-}"
if [[ -z "$SLOT" ]]; then
  echo "usage: tool/bare/embed.sh <linux-x64|linux-arm64|darwin-x64|darwin-arm64|windows-x64|android-arm64|ios-arm64>" >&2
  exit 2
fi

SRC="$ROOT/tool/bare/$SLOT/bare"
if [[ "$SLOT" == windows-x64 ]]; then
  SRC="$ROOT/tool/bare/windows-x64/bare.exe"
fi
if [[ ! -f "$SRC" ]]; then
  echo "no local binary at $SRC (run tool/bare/vendor.sh $SLOT first)" >&2
  exit 1
fi

case "$SLOT" in
  linux-x64|linux-arm64)
    dest="$ROOT/packages/orbits_transport_linux/linux/bare"
    ;;
  darwin-x64|darwin-arm64)
    dest="$ROOT/packages/orbits_transport_macos/macos/bare"
    ;;
  windows-x64)
    dest="$ROOT/packages/orbits_transport_windows/windows/bare.exe"
    ;;
  android-arm64)
    dest="$ROOT/packages/orbits_transport_android/android/src/main/assets/bare"
    ;;
  ios-arm64)
    dest="$ROOT/packages/orbits_transport_ios/ios/bare"
    ;;
  *)
    echo "unknown slot $SLOT" >&2
    exit 2
    ;;
esac

mkdir -p "$(dirname "$dest")"
cp -f "$SRC" "$dest"
chmod +x "$dest" 2>/dev/null || true
echo "embedded $SRC -> $dest"
echo "kBareBinaryShipped stays false until every OS slot is in the app bundle"
