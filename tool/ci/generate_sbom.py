#!/usr/bin/env python3
"""Emit a CycloneDX 1.5 SBOM from pubspec.lock. No vulnerability feed tokens."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import sys
from datetime import datetime, timezone


ALLOWED_LICENSE_MARKERS = (
    "MIT",
    "BSD",
    "APACHE",
    "ISC",
    "ZLIB",
    "MPL",
    "UNLICENSE",
    "CC0",
    "BSL",
    "POSTGRESQL",
    "WTFPL",
    "0BSD",
)

DENIED_LICENSE_MARKERS = (
    "AGPL",
    "GPL-3",
    "GPL-2",
    "SSPL",
    "COMMONS CLAUSE",
)


def parse_lock(text: str) -> list[dict]:
    packages: list[dict] = []
    current: dict | None = None
    section = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if line == "packages:":
            section = "packages"
            continue
        if section != "packages":
            continue
        if re.match(r"^  [A-Za-z0-9_.]+:$", line):
            if current:
                packages.append(current)
            current = {"name": line.strip()[:-1], "version": "", "source": "", "sha256": ""}
            continue
        if current is None:
            continue
        if line.startswith("    version:"):
            current["version"] = line.split(":", 1)[1].strip().strip('"')
        elif line.startswith("    source:"):
            current["source"] = line.split(":", 1)[1].strip()
        elif line.startswith("      sha256:"):
            current["sha256"] = line.split(":", 1)[1].strip()
    if current:
        packages.append(current)
    return packages


def license_from_pub_cache(name: str, version: str) -> str | None:
    cache = pathlib.Path(os.environ.get("PUB_CACHE", pathlib.Path.home() / ".pub-cache"))
    hosted = cache / "hosted"
    if not hosted.exists():
        return None
    for root in hosted.iterdir():
        if not root.is_dir():
            continue
        pkg = root / f"{name}-{version}"
        if not pkg.is_dir():
            continue
        for candidate in ("LICENSE", "LICENSE.md", "COPYING"):
            path = pkg / candidate
            if path.is_file():
                text = path.read_text(errors="replace")[:4000].upper()
                for marker in DENIED_LICENSE_MARKERS:
                    if marker in text:
                        return marker
                for marker in ALLOWED_LICENSE_MARKERS:
                    if marker in text:
                        return marker
                return "UNKNOWN-LICENSE-FILE"
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", default="pubspec.lock")
    parser.add_argument("--out", default="sbom/orbits.cdx.json")
    args = parser.parse_args()
    lock_path = pathlib.Path(args.lock)
    if not lock_path.is_file():
        print(f"missing {lock_path}", file=sys.stderr)
        return 1
    packages = parse_lock(lock_path.read_text())
    if not packages:
        print("pubspec.lock contained no packages", file=sys.stderr)
        return 1
    components = []
    denied = []
    for pkg in packages:
        license_id = license_from_pub_cache(pkg["name"], pkg["version"]) or "NOASSERTION"
        if any(marker in license_id for marker in DENIED_LICENSE_MARKERS):
            denied.append(f"{pkg['name']}@{pkg['version']}: {license_id}")
        components.append(
            {
                "type": "library",
                "name": pkg["name"],
                "version": pkg["version"] or "unknown",
                "bom-ref": f"pkg:pub/{pkg['name']}@{pkg['version'] or 'unknown'}",
                "purl": f"pkg:pub/{pkg['name']}@{pkg['version'] or 'unknown'}",
                "properties": [
                    {"name": "source", "value": pkg["source"] or "unknown"},
                    {"name": "sha256", "value": pkg["sha256"] or ""},
                ],
                "licenses": [{"license": {"id" if license_id not in {"NOASSERTION", "UNKNOWN-LICENSE-FILE"} else "name": license_id}}],
            }
        )
    bom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "tools": [{"name": "orbits-generate-sbom", "version": "1.0.0"}],
            "component": {
                "type": "application",
                "name": "orbits_flutter",
                "version": "workspace",
            },
        },
        "components": components,
    }
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(bom, indent=2, sort_keys=True) + "\n"
    out.write_text(payload)
    digest = hashlib.sha256(payload.encode()).hexdigest()
    print(f"wrote {out} packages={len(components)} sha256={digest}")
    if denied:
        print("license policy denied:", file=sys.stderr)
        for item in denied:
            print(f"  {item}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
