#!/usr/bin/env bash
# Build-time vendor of Holepunch Bare into tool/bare/<os-arch>/.
# NEVER invoked from Dart/Flutter. Production spawn must use a local file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$ROOT/tool/bare/BARE.manifest"
SLOT="${1:-}"
if [[ -z "$SLOT" ]]; then
  echo "usage: tool/bare/vendor.sh <linux-x64|linux-arm64|darwin-x64|darwin-arm64|windows-x64|android-arm64|ios-arm64>" >&2
  exit 2
fi

python3 - "$MANIFEST" "$SLOT" "$ROOT" <<'PY'
import hashlib, json, os, sys, tarfile, urllib.request
from pathlib import Path

manifest_path, slot, root = sys.argv[1], sys.argv[2], sys.argv[3]
manifest = json.loads(Path(manifest_path).read_text())
if manifest.get("remoteFetch") is not False:
    raise SystemExit("refusing vendor: remoteFetch must be false in BARE.manifest")
if manifest.get("downloadUrl") is not None or manifest.get("bundleUrl") is not None:
    raise SystemExit("refusing vendor: Dart spawn URLs must stay null")
vendor = manifest.get("vendor") or {}
version = vendor.get("version")
assets = vendor.get("assets") or {}
asset = assets.get(slot)
if not version or not asset:
    raise SystemExit(f"no vendor pin for {slot}")
url = f"https://github.com/holepunchto/bare-runtime/releases/download/v{version}/{asset['name']}"
dest_dir = Path(root) / manifest["binaries"][slot]
dest_dir = dest_dir.parent
dest_dir.mkdir(parents=True, exist_ok=True)
tgz = dest_dir / asset["name"]
print(f"fetch {url}", flush=True)
urllib.request.urlretrieve(url, tgz)
digest = hashlib.sha256(tgz.read_bytes()).hexdigest()
expected = asset.get("sha256")
if expected and digest != expected:
    raise SystemExit(f"sha256 mismatch for {slot}: {digest} != {expected}")
print(f"sha256 {digest}", flush=True)
with tarfile.open(tgz, "r:gz") as tar:
    members = [m for m in tar.getmembers() if m.name.endswith("/bare") or m.name.endswith("/bare.exe") or m.name.endswith("bare") or m.name.endswith("bare.exe")]
    if not members:
        names = [m.name for m in tar.getmembers()[:20]]
        raise SystemExit(f"no bare binary in tarball; sample={names}")
    member = max(members, key=lambda m: m.size)
    tar.extract(member, path=dest_dir / "_extract")
extracted = next((dest_dir / "_extract").rglob("bare.exe"), None) or next((dest_dir / "_extract").rglob("bare"))
target = Path(root) / manifest["binaries"][slot]
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(extracted.read_bytes())
target.chmod(0o755)
print(f"wrote {target}", flush=True)
PY
