#!/usr/bin/env bash
# Copy the verified official BareKit extract into the Flutter plugin trees
# the same way holepunchto/bare-android and bare-ios consume prebuilds.
# Never commits binaries; destinations are gitignored.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${ORBITS_BARE_CACHE:-$ROOT/build/orbits-bare}"
KIT="$CACHE/bare-kit"

ANDROID_SRC="$KIT/android/bare-kit"
AAR_SRC="$KIT/android/bare-kit.aar"
IOS_SRC="$KIT/ios/BareKit.xcframework"
MACOS_SRC="$KIT/macos/BareKit.xcframework"

ANDROID_LIBS="$ROOT/packages/orbits_transport_android/android/libs"
IOS_DIR="$ROOT/packages/orbits_transport_ios/ios"
MACOS_DIR="$ROOT/packages/orbits_transport_macos/macos"

if [[ ! -d "$ANDROID_SRC" || ! -f "$ANDROID_SRC/classes.jar" ]]; then
  echo "BARE_RUNTIME_MISSING: $ANDROID_SRC/classes.jar" >&2
  exit 1
fi
if [[ ! -d "$IOS_SRC" ]]; then
  echo "BARE_RUNTIME_MISSING: $IOS_SRC" >&2
  exit 1
fi

mkdir -p "$ANDROID_LIBS"
rm -rf "$ANDROID_LIBS/bare-kit"
cp -a "$ANDROID_SRC" "$ANDROID_LIBS/bare-kit"
if [[ -f "$AAR_SRC" ]]; then
  cp -a "$AAR_SRC" "$ANDROID_LIBS/bare-kit.aar"
fi
test -f "$ANDROID_LIBS/bare-kit/classes.jar"
test -f "$ANDROID_LIBS/bare-kit/jni/arm64-v8a/libbare-kit.so"

rm -rf "$IOS_DIR/BareKit.xcframework"
cp -a "$IOS_SRC" "$IOS_DIR/BareKit.xcframework"
test -f "$IOS_DIR/BareKit.xcframework/ios-arm64/BareKit.framework/BareKit"
test -f "$IOS_DIR/BareKit.xcframework/ios-arm64/BareKit.framework/Headers/BareKit.h"

if [[ -d "$MACOS_SRC" ]]; then
  rm -rf "$MACOS_DIR/BareKit.xcframework"
  cp -a "$MACOS_SRC" "$MACOS_DIR/BareKit.xcframework"
  test -d "$MACOS_DIR/BareKit.xcframework"
fi

if [[ -d "$ROOT/tool/connectivity_harness/node_modules/udx-native" ]]; then
  bash "$ROOT/tool/bare/assemble-mobile-worklet.sh"
fi

echo "linked official BareKit into plugin trees"
echo "  $ANDROID_LIBS/bare-kit"
echo "  $IOS_DIR/BareKit.xcframework"
if [[ -d "$MACOS_DIR/BareKit.xcframework" ]]; then
  echo "  $MACOS_DIR/BareKit.xcframework"
fi
