#!/usr/bin/env bash
# Assert a built APK or iOS Runner.app actually contains official BareKit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:-}"
TARGET="${2:-}"

if [[ -z "$MODE" ]]; then
  echo "usage: $0 apk [path] | ios [Runner.app]" >&2
  exit 2
fi

if [[ "$MODE" == "apk" ]]; then
  apk="$TARGET"
  if [[ -z "$apk" ]]; then
    for cand in \
      "$ROOT/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk" \
      "$ROOT/build/app/outputs/flutter-apk/app-release.apk" \
      "$ROOT/build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk" \
      "$ROOT/build/app/outputs/flutter-apk/app-debug.apk"
    do
      if [[ -f "$cand" ]]; then
        apk="$cand"
        break
      fi
    done
  fi
  if [[ -z "$apk" || ! -f "$apk" ]]; then
    echo "BARE_RUNTIME_MISSING: no APK at ${apk:-unset}" >&2
    exit 1
  fi
  listing="$(unzip -l "$apk")"
  if ! grep -E 'lib/.+/libbare-kit\.so' <<<"$listing" >/dev/null; then
    echo "BARE_RUNTIME_MISSING: APK missing libbare-kit.so" >&2
    grep -E 'lib/' <<<"$listing" | head || true
    exit 1
  fi
  if ! grep -q 'flutter_assets/tool/connectivity_harness/src/worklet.js' <<<"$listing"; then
    echo "BARE_RUNTIME_MISSING: APK missing packaged worklet.js" >&2
    exit 1
  fi
  echo "ok packaged BareKit in $apk"
  grep -E 'lib/.+/libbare-kit\.so' <<<"$listing" || true
  exit 0
fi

if [[ "$MODE" == "ios" ]]; then
  app="$TARGET"
  if [[ -z "$app" ]]; then
    for cand in \
      "$ROOT/build/ios/iphoneos/Runner.app" \
      "$ROOT/build/ios/iphonesimulator/Runner.app"
    do
      if [[ -d "$cand" ]]; then
        app="$cand"
        break
      fi
    done
  fi
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "BARE_RUNTIME_MISSING: no Runner.app at ${app:-unset}" >&2
    echo "this host cannot produce an iOS bundle without Xcode" >&2
    exit 1
  fi
  if [[ ! -f "$app/Frameworks/BareKit.framework/BareKit" \
     && ! -f "$app/Frameworks/BareKit.framework/Versions/A/BareKit" ]]; then
    echo "BARE_RUNTIME_MISSING: Runner.app missing BareKit.framework" >&2
    find "$app" -iname '*BareKit*' | head || true
    exit 1
  fi
  if [[ ! -f "$app/Frameworks/App.framework/flutter_assets/tool/connectivity_harness/src/worklet.js" \
     && ! -f "$app/flutter_assets/tool/connectivity_harness/src/worklet.js" ]]; then
    echo "BARE_RUNTIME_MISSING: Runner.app missing packaged worklet.js" >&2
    exit 1
  fi
  echo "ok packaged BareKit in $app"
  exit 0
fi

echo "usage: $0 apk [path] | ios [Runner.app]" >&2
exit 2
