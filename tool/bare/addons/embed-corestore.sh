#!/usr/bin/env bash
# Copy a *local* Holepunch Corestore addon next to the worklet and into
# federated plugin native dirs when the in-tree slot exists.
# NEVER downloads. Dart/Flutter must not invoke this at runtime.
# kHolepunchCorestoreAddonLinked stays false until every shipping OS
# links the addon.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MANIFEST="$ROOT/tool/bare/addons/CORESTORE.manifest"
SRC="${1:-}"

PYTHON_BIN="${PYTHON:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  PYTHON_BIN=python
fi
"$PYTHON_BIN" - "$MANIFEST" <<'PY'
import json, sys
from pathlib import Path
manifest = json.loads(Path(sys.argv[1]).read_text())
if manifest.get("remoteFetch") is not False:
    raise SystemExit("refusing embed: CORESTORE.manifest remoteFetch must be false")
if manifest.get("downloadUrl") is not None or manifest.get("bundleUrl") is not None:
    raise SystemExit("refusing embed: Corestore downloadUrl/bundleUrl must stay null")
if manifest.get("linked") is not False:
    raise SystemExit("refusing embed: linked must stay false until every OS ships the addon")
print("corestore addon remote fetch forbidden; linked stays false", flush=True)
PY

if [[ -n "$SRC" ]]; then
  if [[ "$SRC" == http://* || "$SRC" == https://* || "$SRC" == *://* ]]; then
    echo "refusing remote Corestore addon URL" >&2
    exit 2
  fi
elif [[ -f "$ROOT/tool/bare/addons/corestore.bare" ]]; then
  SRC="$ROOT/tool/bare/addons/corestore.bare"
elif [[ -f "$ROOT/tool/bare/addons/corestore.node" ]]; then
  SRC="$ROOT/tool/bare/addons/corestore.node"
else
  echo "no local Corestore addon; slot stays empty"
  echo "kHolepunchCorestoreAddonLinked stays false"
  exit 0
fi

if [[ ! -f "$SRC" ]]; then
  echo "no file at $SRC" >&2
  exit 1
fi

case "$SRC" in
  *.bare) name="corestore.bare" ;;
  *.node) name="corestore.node" ;;
  *)
    echo "Corestore addon must be a .bare or .node file" >&2
    exit 2
    ;;
esac

copy_one() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cp -f "$SRC" "$dest"
  echo "embedded $SRC -> $dest"
}

copy_one "$ROOT/tool/bare/addons/$name"
copy_one "$ROOT/tool/connectivity_harness/addons/$name"
copy_one "$ROOT/packages/orbits_transport_linux/linux/addons/$name"
copy_one "$ROOT/packages/orbits_transport_macos/macos/addons/$name"
copy_one "$ROOT/packages/orbits_transport_windows/windows/addons/$name"
copy_one "$ROOT/packages/orbits_transport_android/android/src/main/assets/addons/$name"
copy_one "$ROOT/packages/orbits_transport_ios/ios/addons/$name"

# Flat sidecar next to the OS Bare host so CMake/Gradle/podspec can copy
# it into the app bundle as `corestore.bare`.
if [[ "$name" == "corestore.bare" ]]; then
  copy_one "$ROOT/packages/orbits_transport_linux/linux/corestore.bare"
  copy_one "$ROOT/packages/orbits_transport_macos/macos/corestore.bare"
  copy_one "$ROOT/packages/orbits_transport_windows/windows/corestore.bare"
  copy_one "$ROOT/packages/orbits_transport_android/android/src/main/assets/corestore.bare"
  copy_one "$ROOT/packages/orbits_transport_ios/ios/corestore.bare"
  copy_one "$ROOT/tool/connectivity_harness/corestore.bare"
fi

echo "kHolepunchCorestoreAddonLinked stays false until every OS slot is linked"
