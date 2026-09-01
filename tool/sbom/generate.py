#!/usr/bin/env python3
"""Build-time pin list for worklet + Bare vendor hashes.

Not a signed CycloneDX release attestation. Dart/Flutter must never fetch
these URLs. Run with --check in CI to fail if the committed file drifted.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent / "ORBITS.sbom.json"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build() -> dict:
    bundle = json.loads((ROOT / "tool/connectivity_harness/BUNDLE.manifest").read_text())
    bare = json.loads((ROOT / "tool/bare/BARE.manifest").read_text())
    worklet = ROOT / "tool/connectivity_harness/src/worklet.js"
    pkg = ROOT / "tool/connectivity_harness/package.json"
    components = [
        {
            "type": "file",
            "name": "orbits-connectivity-worklet",
            "hashes": [{"alg": "SHA-256", "content": sha256(worklet)}],
            "properties": [
                {"name": "pinnedWorkletSha256", "value": bundle["workletSha256"]},
                {"name": "remoteJs", "value": str(bundle.get("remoteJs")).lower()},
            ],
        },
        {
            "type": "file",
            "name": "orbits-connectivity-package.json",
            "hashes": [{"alg": "SHA-256", "content": sha256(pkg)}],
            "properties": [
                {
                    "name": "pinnedPackageJsonSha256",
                    "value": bundle["packageJsonSha256"],
                }
            ],
        },
    ]
    assets = ((bare.get("vendor") or {}).get("assets") or {})
    for slot, asset in sorted(assets.items()):
        components.append(
            {
                "type": "library",
                "name": f"bare-runtime-{slot}",
                "version": (bare.get("vendor") or {}).get("version"),
                "hashes": [{"alg": "SHA-256", "content": asset["sha256"]}],
                "properties": [
                    {"name": "shipped", "value": str(bare.get("shipped")).lower()},
                    {"name": "remoteFetch", "value": str(bare.get("remoteFetch")).lower()},
                ],
            }
        )
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "component": {
                "name": "orbitsmsg",
                "type": "application",
            },
            "properties": [
                {
                    "name": "note",
                    "value": (
                        "In-tree pin list for CI. Not a signed release SBOM. "
                        "Dart never fetches Bare or worklet JS."
                    ),
                }
            ],
        },
        "components": components,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    doc = build()
    text = json.dumps(doc, indent=2, sort_keys=False) + "\n"
    if args.check:
        if not OUT.exists():
            print("missing", OUT, file=sys.stderr)
            return 1
        if OUT.read_text() != text:
            print("ORBITS.sbom.json is stale; run tool/sbom/generate.py", file=sys.stderr)
            return 1
        bundle = json.loads((ROOT / "tool/connectivity_harness/BUNDLE.manifest").read_text())
        worklet_hash = sha256(ROOT / "tool/connectivity_harness/src/worklet.js")
        if bundle["workletSha256"] != worklet_hash:
            print("BUNDLE.manifest worklet hash drift", file=sys.stderr)
            return 1
        print("sbom pins ok")
        return 0
    OUT.write_text(text)
    print("wrote", OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
