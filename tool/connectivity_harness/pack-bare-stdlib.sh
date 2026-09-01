#!/usr/bin/env bash
# Pack a *local* Holepunch bare-* stdlib zip next to the worklet.
# NEVER downloads. Dart/Flutter must not invoke this at runtime.
# Does not include hyperswarm / hyperdht (those are not the default live path).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NM="$ROOT/node_modules"
OUT="$ROOT/bare_stdlib.zip"

if [[ ! -f "$NM/bare-fs/package.json" ]]; then
  echo "no local node_modules/bare-fs (run vendor-bare-modules.sh first)" >&2
  echo "kBareBinaryShipped stays false"
  exit 1
fi

PYTHON_BIN="${PYTHON:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  PYTHON_BIN=python
fi

"$PYTHON_BIN" - "$NM" "$OUT" <<'PY'
import json, os, shutil, sys, tempfile, zipfile
from pathlib import Path

nm = Path(sys.argv[1])
out = Path(sys.argv[2])
roots = [
    "bare-fs",
    "bare-path",
    "bare-crypto",
    "bare-net",
    "bare-events",
    "bare-os",
    "bare-process",
]
forbidden = (
    "hyperswarm",
    "hyperdht",
    "dht-rpc",
    "hyperswarm-secret-stream",
    "blind-relay",
)


def is_forbidden(name: str) -> bool:
    n = name.lower().replace("\\", "/")
    if "://" in n:
        return True
    return any(part in n for part in forbidden)


def deps_of(pkg_dir: Path) -> list[str]:
    manifest = pkg_dir / "package.json"
    if not manifest.is_file():
        return []
    data = json.loads(manifest.read_text())
    deps = data.get("dependencies") or {}
    return [str(k) for k in deps.keys()]


seen: set[str] = set()
queue = list(roots)
needed: list[str] = []
while queue:
    name = queue.pop(0)
    if name in seen or is_forbidden(name):
        continue
    pkg = nm / name
    if not (pkg / "package.json").is_file():
        continue
    seen.add(name)
    needed.append(name)
    for dep in deps_of(pkg):
        if dep not in seen and not is_forbidden(dep):
            queue.append(dep)

staging = Path(tempfile.mkdtemp(prefix="orbits-bare-stdlib-"))
try:
    dest_root = staging / "node_modules"
    dest_root.mkdir(parents=True)
    for name in needed:
        src = nm / name
        dst = dest_root / name
        shutil.copytree(
            src,
            dst,
            ignore=shutil.ignore_patterns("hyperswarm*", "hyperdht*", ".bin"),
            symlinks=False,
        )
    if out.exists():
        out.unlink()
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in dest_root.rglob("*"):
            if not path.is_file():
                continue
            rel = path.relative_to(staging).as_posix()
            if is_forbidden(rel) or ".." in rel.split("/"):
                continue
            zf.write(path, rel)
finally:
    shutil.rmtree(staging, ignore_errors=True)

names = zipfile.ZipFile(out).namelist()
joined = "\n".join(names)
if "node_modules/bare-fs/package.json" not in names:
    raise SystemExit("packed zip missing node_modules/bare-fs/package.json")
if "hyperswarm" in joined.lower() or "hyperdht" in joined.lower():
    raise SystemExit("refusing zip that contains hyperswarm/hyperdht")
print(f"packed {len(needed)} packages -> {out} ({out.stat().st_size} bytes)")
print("kBareBinaryShipped stays false")
PY
echo "bare stdlib zip is local-only; Dart must not fetch this tree"
