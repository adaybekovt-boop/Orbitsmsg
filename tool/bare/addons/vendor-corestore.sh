#!/usr/bin/env bash
# Copy a *local* Holepunch Corestore native addon into the in-tree slot.
# NEVER downloads. Dart/Flutter must not invoke this at runtime.
# kHolepunchCorestoreAddonLinked stays false until every shipping OS
# links the addon. Bare 1.31 needs a .bare addon, not Node's .node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MANIFEST="$ROOT/tool/bare/addons/CORESTORE.manifest"
SRC="${1:-${CORESTORE_ADDON:-}}"

PYTHON_BIN="${PYTHON:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  PYTHON_BIN=python
fi
"$PYTHON_BIN" - "$MANIFEST" <<'PY'
import json, sys
from pathlib import Path
manifest = json.loads(Path(sys.argv[1]).read_text())
if manifest.get("remoteFetch") is not False:
    raise SystemExit("refusing vendor: CORESTORE.manifest remoteFetch must be false")
if manifest.get("downloadUrl") is not None or manifest.get("bundleUrl") is not None:
    raise SystemExit("refusing vendor: Corestore downloadUrl/bundleUrl must stay null")
if manifest.get("linked") is not False:
    raise SystemExit("refusing vendor: linked must stay false until every OS ships the addon")
print("corestore addon remote fetch forbidden; linked stays false", flush=True)
PY

if [[ -z "$SRC" ]]; then
  echo "no local Corestore addon (pass a path or CORESTORE_ADDON); slot stays empty"
  echo "kHolepunchCorestoreAddonLinked stays false"
  exit 0
fi
if [[ "$SRC" == http://* || "$SRC" == https://* ]]; then
  echo "refusing remote Corestore addon URL" >&2
  exit 2
fi
if [[ ! -f "$SRC" ]]; then
  echo "no file at $SRC" >&2
  exit 1
fi

case "$SRC" in
  *.bare)
    dest="$ROOT/tool/bare/addons/corestore.bare"
    ;;
  *.node|*)
    dest="$ROOT/tool/bare/addons/corestore.node"
    ;;
esac
mkdir -p "$(dirname "$dest")"
cp -f "$SRC" "$dest"
echo "copied $SRC -> $dest"
echo "kHolepunchCorestoreAddonLinked stays false until every OS slot is linked"
