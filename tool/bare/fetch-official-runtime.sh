#!/usr/bin/env bash
# Build-time fetch of pinned official Holepunch bare-runtime artifacts.
# Never invoked by the running application.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PINS="$ROOT/tool/bare/pins.json"
CACHE="${ORBITS_BARE_CACHE:-$ROOT/build/orbits-bare}"
ONLY="${1:-}"

if [[ ! -f "$PINS" ]]; then
  echo "missing $PINS" >&2
  exit 1
fi

python3 - "$PINS" "$CACHE" "$ONLY" <<'PY'
import hashlib, json, os, sys, tarfile, urllib.request
from pathlib import Path

pins_path, cache_root, only = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
pins = json.loads(Path(pins_path).read_text())
if pins.get("remoteFetchAtRuntime") is not False:
    raise SystemExit("pins.json must forbid runtime fetch")
runtime = pins["bareRuntime"]
base = runtime["releaseBase"]
artifacts = runtime["artifacts"]

def platform_key():
    import platform
    sysname = platform.system().lower()
    machine = platform.machine().lower()
    if sysname == "linux":
        os_name = "linux"
    elif sysname == "darwin":
        os_name = "darwin"
    elif sysname.startswith("mingw") or sysname == "windows":
        os_name = "win32"
    else:
        raise SystemExit(f"unsupported host {sysname}")
    if machine in {"x86_64", "amd64"}:
        arch = "x64"
    elif machine in {"aarch64", "arm64"}:
        arch = "arm64"
    else:
        raise SystemExit(f"unsupported arch {machine}")
    return f"{os_name}-{arch}"

wanted = [only] if only and only != "--all" and only != "--kit" else (
    list(artifacts) if only == "--all" else [platform_key()]
)
if only == "--kit":
    wanted = []

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

for key in wanted:
    spec = artifacts[key]
    dest = cache_root / key
    dest.mkdir(parents=True, exist_ok=True)
    tgz = dest / spec["asset"]
    url = f"{base}/{spec['asset']}"
    if not tgz.is_file() or sha256_file(tgz) != spec["sha256"]:
        print(f"fetch {url}")
        req = urllib.request.Request(url, headers={"User-Agent": "orbits-bare-fetch/1"})
        with urllib.request.urlopen(req, timeout=120) as resp, tgz.open("wb") as out:
            while True:
                chunk = resp.read(1024 * 1024)
                if not chunk:
                    break
                out.write(chunk)
    digest = sha256_file(tgz)
    if digest != spec["sha256"]:
        tgz.unlink(missing_ok=True)
        raise SystemExit(f"{spec['asset']} sha256 {digest} != pinned {spec['sha256']}")
    with tarfile.open(tgz, "r:gz") as tf:
        tf.extractall(dest / "extract", filter="data")
    binary_name = spec.get("binaryName", "bare")
    candidates = list((dest / "extract").rglob(binary_name))
    if not candidates:
        raise SystemExit(f"no {binary_name} in {spec['asset']}")
    binary = dest / binary_name
    binary.write_bytes(candidates[0].read_bytes())
    binary.chmod(0o755)
    sidecar = dest / f"{binary_name}.sha256"
    actual = sha256_file(binary)
    expected_bin = spec.get("binarySha256")
    if expected_bin and actual != expected_bin:
        raise SystemExit(f"{binary_name} sha256 {actual} != pinned {expected_bin}")
    sidecar.write_text(actual + "\n")
    license_src = next((dest / "extract").rglob("LICENSE"), None)
    notice_src = next((dest / "extract").rglob("NOTICE"), None)
    if license_src:
        (dest / "LICENSE").write_bytes(license_src.read_bytes())
    if notice_src:
        (dest / "NOTICE").write_bytes(notice_src.read_bytes())
    print(f"verified {key} {binary} sha256={actual}")

if only == "--kit":
    kit = pins["bareKit"]["prebuilds"]
    url = kit["url"]
    dest = cache_root / "bare-kit"
    dest.mkdir(parents=True, exist_ok=True)
    zpath = dest / "prebuilds.zip"
    print(f"fetch {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "orbits-bare-fetch/1"})
    with urllib.request.urlopen(req, timeout=300) as resp, zpath.open("wb") as out:
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
    digest = sha256_file(zpath)
    pinned = kit.get("sha256")
    sidecar = dest / "prebuilds.zip.sha256"
    sidecar.write_text(digest + "\n")
    if pinned and digest != pinned:
        raise SystemExit(f"prebuilds.zip sha256 {digest} != pinned {pinned}")
    print(f"verified bare-kit prebuilds.zip sha256={digest}")
PY
