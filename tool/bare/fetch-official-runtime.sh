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
import hashlib
import json
import os
import platform
import subprocess
import sys
import tarfile
import time
import urllib.request
from pathlib import Path

pins_path, cache_root, only = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
pins = json.loads(Path(pins_path).read_text())
if pins.get("remoteFetchAtRuntime") is not False:
    raise SystemExit("pins.json must forbid runtime fetch")
runtime = pins["bareRuntime"]
base = runtime["releaseBase"]
artifacts = runtime["artifacts"]


def platform_key():
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


wanted = (
    [only]
    if only and only not in {"--all", "--kit"}
    else (list(artifacts) if only == "--all" else [platform_key()])
)
if only == "--kit":
    wanted = []


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, dest: Path, timeout: int = 180) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".partial")
    last_error = None
    for attempt in range(1, 7):
        print(f"fetch {url} (attempt {attempt}/6)")
        tmp.unlink(missing_ok=True)
        try:
            if _curl(url, tmp, timeout):
                tmp.replace(dest)
                return
        except Exception as exc:  # noqa: BLE001 — surface last fetch error
            last_error = exc
        time.sleep(min(2 ** attempt, 16))
    raise SystemExit(f"failed to fetch {url}: {last_error}")


def _curl(url: str, dest: Path, timeout: int) -> bool:
    curl = _which("curl")
    if curl:
        cmd = [
            curl,
            "-fL",
            "--connect-timeout",
            "30",
            "--max-time",
            str(timeout),
            "--retry",
            "5",
            "--retry-delay",
            "3",
            "--retry-all-errors",
            "-A",
            "orbits-bare-fetch/1",
            "-o",
            str(dest),
            url,
        ]
        result = subprocess.run(cmd, check=False)
        return result.returncode == 0 and dest.is_file() and dest.stat().st_size > 0
    req = urllib.request.Request(url, headers={"User-Agent": "orbits-bare-fetch/1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp, dest.open("wb") as out:
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
    return dest.is_file() and dest.stat().st_size > 0


def _which(name: str):
    paths = os.environ.get("PATH", "").split(os.pathsep)
    for folder in paths:
        candidate = Path(folder) / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


for key in wanted:
    spec = artifacts[key]
    dest = cache_root / key
    dest.mkdir(parents=True, exist_ok=True)
    tgz = dest / spec["asset"]
    url = f"{base}/{spec['asset']}"
    if not tgz.is_file() or sha256_file(tgz) != spec["sha256"]:
        download(url, tgz)
    digest = sha256_file(tgz)
    if digest != spec["sha256"]:
        tgz.unlink(missing_ok=True)
        raise SystemExit(f"{spec['asset']} sha256 {digest} != pinned {spec['sha256']}")
    extract = dest / "extract"
    if extract.exists():
        for child in extract.rglob("*"):
            if child.is_file() or child.is_symlink():
                child.unlink()
    extract.mkdir(parents=True, exist_ok=True)
    with tarfile.open(tgz, "r:gz") as tf:
        tf.extractall(extract, filter="data")
    binary_name = spec.get("binaryName", "bare")
    candidates = list(extract.rglob(binary_name))
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
    license_src = next(extract.rglob("LICENSE"), None)
    notice_src = next(extract.rglob("NOTICE"), None)
    if license_src:
        (dest / "LICENSE").write_bytes(license_src.read_bytes())
    if notice_src:
        (dest / "NOTICE").write_bytes(notice_src.read_bytes())
    print(f"verified {key} {binary} sha256={actual}")

if only == "--kit":
    import shutil
    import zipfile

    kit = pins["bareKit"]["prebuilds"]
    url = kit["url"]
    dest = cache_root / "bare-kit"
    dest.mkdir(parents=True, exist_ok=True)
    zpath = dest / "prebuilds.zip"
    pinned = kit.get("sha256")
    if not pinned:
        raise SystemExit(
            "BARE_RUNTIME_MISSING: pins.json bareKit.prebuilds.sha256 is null"
        )
    if not zpath.is_file() or sha256_file(zpath) != pinned:
        download(url, zpath, timeout=900)
    digest = sha256_file(zpath)
    sidecar = dest / "prebuilds.zip.sha256"
    sidecar.write_text(digest + "\n")
    if digest != pinned:
        zpath.unlink(missing_ok=True)
        raise SystemExit(f"prebuilds.zip sha256 {digest} != pinned {pinned}")

    extract_root = dest / "extract"
    if extract_root.exists():
        shutil.rmtree(extract_root)
    extract_root.mkdir(parents=True, exist_ok=True)

    extracted = []
    with zipfile.ZipFile(zpath) as zf:
        for info in zf.infolist():
            name = info.filename.replace("\\", "/")
            if name.startswith("android/bare-kit/") or name == "android/bare-kit":
                zf.extract(info, extract_root)
                extracted.append(name)
            elif name.startswith("ios/BareKit.xcframework/") or name == "ios/BareKit.xcframework":
                zf.extract(info, extract_root)
                extracted.append(name)
            elif name.startswith("macos/BareKit.xcframework/") or name == "macos/BareKit.xcframework":
                zf.extract(info, extract_root)
                extracted.append(name)
            elif name.startswith("darwin/BareKit.xcframework/") or name == "darwin/BareKit.xcframework":
                zf.extract(info, extract_root)
                extracted.append(name)
            elif name.startswith("apple/BareKit.xcframework/") or name == "apple/BareKit.xcframework":
                zf.extract(info, extract_root)
                extracted.append(name)
            elif name == "linux/x64/libbare-kit.so" or name == "linux/arm64/libbare-kit.so":
                zf.extract(info, extract_root)
                extracted.append(name)
            elif name in {"LICENSE", "NOTICE"} or name.endswith("/LICENSE") or name.endswith("/NOTICE"):
                zf.extract(info, extract_root)
                extracted.append(name)
    if not extracted:
        raise SystemExit("BARE_RUNTIME_MISSING: prebuilds.zip had no android/ios BareKit tree")

    android_src = extract_root / "android" / "bare-kit"
    ios_src = extract_root / "ios" / "BareKit.xcframework"
    macos_src = extract_root / "macos" / "BareKit.xcframework"
    darwin_src = extract_root / "darwin" / "BareKit.xcframework"
    apple_src = extract_root / "apple" / "BareKit.xcframework"
    android_dst = dest / "android" / "bare-kit"
    ios_dst = dest / "ios" / "BareKit.xcframework"
    macos_dst = dest / "macos" / "BareKit.xcframework"
    if android_src.is_dir():
        if android_dst.exists():
            shutil.rmtree(android_dst)
        shutil.copytree(android_src, android_dst)
        aar_path = dest / "android" / "bare-kit.aar"
        with zipfile.ZipFile(aar_path, "w", zipfile.ZIP_DEFLATED) as aar:
            for item in android_dst.rglob("*"):
                if item.is_file():
                    aar.write(item, item.relative_to(android_dst).as_posix())
        print(f"packaged official exploded AAR -> {aar_path}")
    if ios_src.is_dir():
        if ios_dst.exists():
            shutil.rmtree(ios_dst)
        shutil.copytree(ios_src, ios_dst)
    macos_from = macos_src if macos_src.is_dir() else (
        darwin_src if darwin_src.is_dir() else (
            apple_src if apple_src.is_dir() else None
        )
    )
    if macos_from is not None:
        if macos_dst.exists():
            shutil.rmtree(macos_dst)
        shutil.copytree(macos_from, macos_dst)

    for arch in ("x64", "arm64"):
        so_src = extract_root / "linux" / arch / "libbare-kit.so"
        if so_src.is_file():
            so_dst = dest / "linux" / arch / "libbare-kit.so"
            so_dst.parent.mkdir(parents=True, exist_ok=True)
            so_dst.write_bytes(so_src.read_bytes())

    license_src = next(extract_root.rglob("LICENSE"), None)
    if license_src and license_src.is_file():
        (dest / "LICENSE").write_bytes(license_src.read_bytes())
    notice_src = next(extract_root.rglob("NOTICE"), None)
    if notice_src and notice_src.is_file():
        (dest / "NOTICE").write_bytes(notice_src.read_bytes())

    aar_path = dest / "android" / "bare-kit.aar"
    layout = {
        "sha256": digest,
        "android": str(android_dst) if android_dst.is_dir() else None,
        "aar": str(aar_path) if aar_path.is_file() else None,
        "ios": str(ios_dst) if ios_dst.is_dir() else None,
        "macos": str(macos_dst) if macos_dst.is_dir() else None,
        "classesJar": str(android_dst / "classes.jar")
        if (android_dst / "classes.jar").is_file()
        else None,
        "linuxX64": str(dest / "linux" / "x64" / "libbare-kit.so")
        if (dest / "linux" / "x64" / "libbare-kit.so").is_file()
        else None,
    }
    (dest / "layout.json").write_text(json.dumps(layout, indent=2) + "\n")
    if not layout["classesJar"] and not layout["ios"]:
        raise SystemExit(
            "BARE_RUNTIME_MISSING: extracted tree missing classes.jar and BareKit.xcframework"
        )
    print(f"verified bare-kit prebuilds.zip sha256={digest}")
    if layout["android"]:
        print(f"extracted android/bare-kit -> {android_dst}")
    if layout["ios"]:
        print(f"extracted ios/BareKit.xcframework -> {ios_dst}")
    if layout["macos"]:
        print(f"extracted macos BareKit.xcframework -> {macos_dst}")
    if layout["linuxX64"]:
        print(f"extracted linux/x64/libbare-kit.so -> {layout['linuxX64']}")

    link = Path(pins_path).resolve().parent / "link-official-kit.sh"
    if link.is_file():
        result = subprocess.run(["bash", str(link)], check=False)
        if result.returncode != 0:
            raise SystemExit("BARE_RUNTIME_MISSING: link-official-kit.sh failed")
PY
