#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import hashlib, json
from pathlib import Path
manifest = json.loads(Path("tool/connectivity_harness/BUNDLE.manifest").read_text())
if manifest.get("remoteJs") is not False:
    raise SystemExit("BUNDLE.manifest must set remoteJs=false")
files = manifest.get("files")
if not isinstance(files, dict) or "worklet.js" not in files:
    # Back-compat: single worklet hash.
    worklet = Path("tool/connectivity_harness/src/worklet.js").read_bytes()
    digest = hashlib.sha256(worklet).hexdigest()
    pinned = manifest.get("workletSha256")
    if pinned != digest:
        raise SystemExit(f"worklet hash {digest} != pinned {pinned}")
    print(f"worklet.js sha256={digest}")
else:
    src = Path("tool/connectivity_harness/src")
    for name, expected in files.items():
        path = src / name
        if not path.is_file():
            raise SystemExit(f"missing bundled file {name}")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != expected:
            raise SystemExit(f"{name} hash {digest} != pinned {expected}")
        print(f"{name} sha256={digest}")
    if manifest.get("workletSha256") != files.get("worklet.js"):
        raise SystemExit("workletSha256 must match files.worklet.js")
PY
