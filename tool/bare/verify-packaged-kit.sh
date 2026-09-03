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
  for asset in \
    flutter_assets/tool/connectivity_harness/src/worklet.js \
    flutter_assets/tool/connectivity_harness/src/mux.js \
    flutter_assets/tool/connectivity_harness/src/ipc.js \
    flutter_assets/tool/connectivity_harness/src/swarm.js \
    flutter_assets/tool/connectivity_harness/src/bare_compat.js \
    flutter_assets/tool/connectivity_harness/src/discovery.js \
    flutter_assets/tool/connectivity_harness/src/corestore_journal.js
  do
    if ! grep -q "$asset" <<<"$listing"; then
      echo "BARE_RUNTIME_MISSING: APK missing $asset" >&2
      exit 1
    fi
  done
  if ! grep -q 'assets/orbits-worklet-modules.zip' <<<"$listing"; then
    echo "BARE_WORKLET_FAILED: APK missing orbits-worklet-modules.zip" >&2
    exit 1
  fi
  echo "ok packaged BareKit in $apk"
  grep -E 'lib/.+/libbare-kit\.so' <<<"$listing" || true
  grep -E 'orbits-worklet-modules.zip|worklet.js' <<<"$listing" || true
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
  worklet_ok=0
  for root in \
    "$app/Frameworks/App.framework/flutter_assets/tool/connectivity_harness/src" \
    "$app/flutter_assets/tool/connectivity_harness/src"
  do
    if [[ -f "$root/worklet.js" && -f "$root/ipc.js" && -f "$root/swarm.js" && -f "$root/bare_compat.js" ]]; then
      worklet_ok=1
    fi
  done
  if [[ "$worklet_ok" -ne 1 ]]; then
    echo "BARE_RUNTIME_MISSING: Runner.app missing packaged worklet modules" >&2
    exit 1
  fi
  if ! find "$app" \( -name 'orbits-worklet-modules.zip' -o -path '*/node_modules/hyperswarm/package.json' \) | grep -q .; then
    echo "BARE_WORKLET_FAILED: Runner.app missing worklet node_modules zip" >&2
    find "$app" -iname '*worklet*' -o -iname '*hyperswarm*' | head || true
    exit 1
  fi
  echo "ok packaged BareKit in $app"
  exit 0
fi

echo "usage: $0 apk [path] | ios [Runner.app]" >&2
exit 2
