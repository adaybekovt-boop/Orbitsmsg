#!/usr/bin/env bash
# Reproducible Bare packaging. Never fetches executable JS at app runtime.
# Official Holepunch tarballs are consumed only after SHA-256 verification.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/tool/connectivity_harness/BUNDLE.manifest"
PINS="$ROOT/tool/bare/pins.json"
MODE="${1:-}"

if [[ ! -f "$MANIFEST" ]]; then
  echo "missing BUNDLE.manifest" >&2
  exit 1
fi
if [[ ! -f "$PINS" ]]; then
  echo "missing tool/bare/pins.json" >&2
  exit 1
fi

echo "local worklet manifest: $MANIFEST"
echo "official pins: $PINS"

if [[ "$MODE" == "--from-source" ]]; then
  if ! command -v bare-make >/dev/null 2>&1; then
    echo "blocked: bare-make is not installed; cannot rebuild Bare from source" >&2
    echo "blocked: install the Holepunch bare-make toolchain, then retry" >&2
    exit 2
  fi
  SRC="${ORBITS_BARE_SRC:-$ROOT/build/orbits-bare/src/bare}"
  if [[ ! -d "$SRC" ]]; then
    echo "blocked: pinned Bare source checkout is missing at $SRC" >&2
    echo "blocked: clone holepunchto/bare @ 99dee2a6e56979bca696b6c21b8d4acc95e10e6a" >&2
    exit 2
  fi
  (cd "$SRC" && bare-make generate && bare-make build)
  echo "source build completed in $SRC"
  exit 0
fi

if ! bash "$ROOT/tool/bare/fetch-official-runtime.sh"; then
  echo "blocked: official pinned Bare tarball could not be fetched or verified" >&2
  exit 2
fi
bash "$ROOT/tool/bare/verify-runtime.sh"

if [[ ! -x "${ORBITS_BARE_BIN:-}" ]]; then
  HOST_BIN="$(python3 - <<PY
import platform
from pathlib import Path
root = Path("$ROOT") / "build" / "orbits-bare"
sysname = platform.system().lower()
machine = platform.machine().lower()
os_name = {"linux":"linux","darwin":"darwin","windows":"win32"}.get(sysname,"linux")
arch = "x64" if machine in {"x86_64","amd64"} else "arm64"
name = "bare.exe" if os_name == "win32" else "bare"
print(root / f"{os_name}-{arch}" / name)
PY
)"
  if [[ -x "$HOST_BIN" ]]; then
    export ORBITS_BARE_BIN="$HOST_BIN"
  fi
fi

if [[ ! -x "${ORBITS_BARE_BIN:-}" ]]; then
  echo "blocked: verified Bare binary is not executable" >&2
  exit 2
fi

echo "bare binary: $ORBITS_BARE_BIN"

# Platform signing credentials are never invented here.
if [[ "${ORBITS_REQUIRE_PLATFORM_SIGNING:-}" == "1" ]]; then
  missing=()
  if [[ -z "${ANDROID_UPLOAD_KEYSTORE_BASE64:-}" ]]; then
    missing+=("ANDROID_UPLOAD_KEYSTORE_BASE64")
  fi
  if [[ -z "${WINDOWS_CERT_PFX_BASE64:-}" ]]; then
    missing+=("WINDOWS_CERT_PFX_BASE64")
  fi
  if (( ${#missing[@]} > 0 )); then
    echo "blocked: platform signing secrets missing: ${missing[*]}" >&2
    echo "blocked: Apple distribution cert / provision profile also required for store iOS" >&2
    exit 2
  fi
fi

echo "reproducible Bare artifact verified (official tarball, SHA-256 pinned)"
