#!/usr/bin/env bash
# Assemble the on-device worklet tree (src + production node_modules).
# Does not fetch remote JS. Requires a prior npm ci in the harness.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="$ROOT/tool/connectivity_harness"
STAGE="$ROOT/build/orbits-bare/mobile-worklet"
ZIP="$ROOT/build/orbits-bare/mobile-worklet.zip"
IOS_ZIP="$ROOT/packages/orbits_transport_ios/ios/orbits-worklet-modules.zip"

if [[ ! -f "$HARNESS/src/worklet.js" ]]; then
  echo "BARE_WORKLET_FAILED: missing $HARNESS/src/worklet.js" >&2
  exit 1
fi
if [[ ! -d "$HARNESS/node_modules/hyperswarm" ]]; then
  echo "BARE_WORKLET_FAILED: run npm ci --prefix tool/connectivity_harness first" >&2
  exit 1
fi
for addon in \
  "$HARNESS/node_modules/udx-native/prebuilds/android-arm64/udx-native.bare" \
  "$HARNESS/node_modules/udx-native/prebuilds/ios-arm64/udx-native.bare"
do
  if [[ ! -f "$addon" ]]; then
    echo "BARE_WORKLET_FAILED: missing mobile addon $addon" >&2
    exit 1
  fi
done

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$HARNESS/src/." "$STAGE/"
cp -a "$HARNESS/package.json" "$STAGE/package.json"
cp -a "$HARNESS/node_modules" "$STAGE/node_modules"

# The zip is consumed by the Android plugin assets copy, the iOS plugin
# resource, and by verify scripts.
rm -f "$ZIP"
(
  cd "$STAGE"
  zip -qr "$ZIP" .
)
cp -a "$ZIP" "$IOS_ZIP"

echo "ok mobile worklet zip $(wc -c < "$ZIP") bytes -> $ZIP"
echo "ok copied iOS worklet zip -> $IOS_ZIP"
