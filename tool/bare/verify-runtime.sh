#!/usr/bin/env bash
# Verify a fetched or packaged official Bare binary against pins.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PINS="$ROOT/tool/bare/pins.json"
CACHE="${ORBITS_BARE_CACHE:-$ROOT/build/orbits-bare}"
python3 - "$PINS" "$CACHE" "${1:-}" <<'PY'
import hashlib, json, platform, sys
from pathlib import Path

pins = json.loads(Path(sys.argv[1]).read_text())
cache = Path(sys.argv[2])
only = sys.argv[3]

def host_key():
    sysname = platform.system().lower()
    machine = platform.machine().lower()
    os_name = {"linux": "linux", "darwin": "darwin", "windows": "win32"}.get(sysname)
    if os_name is None:
        raise SystemExit(f"unsupported {sysname}")
    arch = "x64" if machine in {"x86_64", "amd64"} else "arm64" if machine in {"aarch64", "arm64"} else None
    if arch is None:
        raise SystemExit(f"unsupported {machine}")
    return f"{os_name}-{arch}"

if only == "--kit":
    kit = pins["bareKit"]["prebuilds"]
    pinned = kit.get("sha256")
    dest = cache / "bare-kit"
    zpath = dest / "prebuilds.zip"
    sidecar = dest / "prebuilds.zip.sha256"
    android = dest / "android" / "bare-kit" / "classes.jar"
    ios = dest / "ios" / "BareKit.xcframework"
    if not pinned:
        raise SystemExit("BARE_RUNTIME_MISSING: pins.json bareKit.prebuilds.sha256 is null")
    if not zpath.is_file() and not android.is_file() and not ios.is_dir():
        raise SystemExit(
            "BARE_RUNTIME_MISSING: run bash tool/bare/fetch-official-runtime.sh --kit"
        )
    if zpath.is_file():
        digest = hashlib.sha256(zpath.read_bytes()).hexdigest()
        if digest != pinned:
            raise SystemExit(f"BUNDLE_TAMPERED: {digest} != pinned {pinned}")
        if sidecar.is_file():
            expected = sidecar.read_text().strip().split()[0]
            if digest != expected:
                raise SystemExit(f"BUNDLE_TAMPERED: {digest} != {expected}")
        print(f"ok bare-kit prebuilds.zip sha256={digest}")
    if android.is_file():
        print(f"ok android classes.jar {android}")
    if ios.is_dir():
        print(f"ok ios BareKit.xcframework {ios}")
    if pins.get("remoteFetchAtRuntime") is not False:
        raise SystemExit("pins allow runtime fetch")
    raise SystemExit(0)

key = only or host_key()
spec = pins["bareRuntime"]["artifacts"][key]
name = spec.get("binaryName", "bare")
binary = cache / key / name
sidecar = cache / key / f"{name}.sha256"
if not binary.is_file():
    raise SystemExit(f"BARE_RUNTIME_MISSING: {binary}")
digest = hashlib.sha256(binary.read_bytes()).hexdigest()
if sidecar.is_file():
    expected = sidecar.read_text().strip().split()[0]
    if digest != expected:
        raise SystemExit(f"BUNDLE_TAMPERED: {digest} != {expected}")
pinned = spec.get("binarySha256")
if pinned and digest != pinned:
    raise SystemExit(f"BUNDLE_TAMPERED: {digest} != pinned {pinned}")
if pins.get("remoteFetchAtRuntime") is not False:
    raise SystemExit("pins allow runtime fetch")
print(f"ok {key} {binary} sha256={digest}")
PY
