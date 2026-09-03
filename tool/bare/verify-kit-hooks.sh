#!/usr/bin/env bash
# Deterministic BareKit mobile-hook check. Does not download prebuilds.zip.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PINS="$ROOT/tool/bare/pins.json"
ANDROID_GRADLE="$ROOT/packages/orbits_transport_android/android/build.gradle"
IOS_PODSPEC="$ROOT/packages/orbits_transport_ios/ios/orbits_transport_ios.podspec"
MACOS_PODSPEC="$ROOT/packages/orbits_transport_macos/macos/orbits_transport_macos.podspec"
ANDROID_KT="$ROOT/packages/orbits_transport_android/android/src/main/kotlin/app/orbits/transport/OrbitsBareRuntime.kt"
IOS_SWIFT="$ROOT/packages/orbits_transport_ios/ios/Classes/OrbitsBareRuntime.swift"
FETCH="$ROOT/tool/bare/fetch-official-runtime.sh"

python3 - "$PINS" "$ANDROID_GRADLE" "$IOS_PODSPEC" "$MACOS_PODSPEC" "$ANDROID_KT" "$IOS_SWIFT" "$FETCH" <<'PY'
import json
import re
import sys
from pathlib import Path

pins_path, gradle_path, ios_pod_path, macos_pod_path, kt_path, swift_path, fetch_path = (
    Path(p) for p in sys.argv[1:]
)
pins = json.loads(pins_path.read_text())
if pins.get("remoteFetchAtRuntime") is not False:
    raise SystemExit("pins.json must forbid runtime fetch")
kit = pins["bareKit"]
if kit["version"] != "2.4.3":
    raise SystemExit(f"bare-kit version {kit['version']} != 2.4.3")
if kit["commit"] != "d6960d8cb63f500e064f8cf6c4ea72aaf3cc1233":
    raise SystemExit("bare-kit commit is not the pinned 2.4.3 tag")
digest = kit["prebuilds"].get("sha256")
if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
    raise SystemExit("BARE_RUNTIME_MISSING: pins.json bareKit.prebuilds.sha256 must be 64 hex")

url_re = re.compile(r"https?://[a-zA-Z0-9]")
for label, path in (
    ("android gradle", gradle_path),
    ("android kotlin", kt_path),
    ("ios swift", swift_path),
):
    text = path.read_text()
    if url_re.search(text):
        raise SystemExit(f"{label} must not embed a fetchable URL")
for label, path in (("ios podspec", ios_pod_path), ("macos podspec", macos_pod_path)):
    hook = path.read_text().split("kit_root = ENV['ORBITS_BARE_KIT']", 1)
    if len(hook) != 2:
        raise SystemExit(f"{label} missing ORBITS_BARE_KIT hook")
    if url_re.search(hook[1]):
        raise SystemExit(f"{label} kit hook must not embed a fetchable URL")

gradle = gradle_path.read_text()
if "classes.jar" not in gradle or "ORBITS_BARE_KIT" not in gradle:
    raise SystemExit("android gradle must consume a local verified classes.jar path")
if "jni" not in gradle:
    raise SystemExit("android gradle must wire official bare-kit jni when present")

ios_pod = ios_pod_path.read_text()
if "vendored_frameworks" not in ios_pod or "BareKit.xcframework" not in ios_pod:
    raise SystemExit("ios podspec must vend a local BareKit.xcframework when present")
if "ORBITS_BARE_KIT" not in ios_pod:
    raise SystemExit("ios podspec must honor ORBITS_BARE_KIT")

macos_pod = macos_pod_path.read_text()
if "BareKit.xcframework" not in macos_pod or "ORBITS_BARE_KIT" not in macos_pod:
    raise SystemExit("macos podspec must honor a local BareKit.xcframework path")

kt = kt_path.read_text()
if "to.holepunch.bare.kit.Worklet" not in kt:
    raise SystemExit("android host must resolve official Worklet by reflection")
if 'start.invoke(worklet, "/orbits/worklet.js", source, null)' in kt:
    raise SystemExit("android host must not invent a 3-arg Worklet.start")
if "UTF-8" not in kt:
    raise SystemExit("android host must use official start(filename, source, charset, args)")
if "Redirect.DISCARD" in kt:
    raise SystemExit("android host must not use Java 9 ProcessBuilder.Redirect.DISCARD")

swift = swift_path.read_text()
if "canImport(BareKit)" not in swift:
    raise SystemExit("ios host must keep #if canImport(BareKit)")
if "defaultWorkletConfiguration" not in swift:
    raise SystemExit("ios host must use official BareWorkletConfiguration.defaultWorkletConfiguration")
if "BareWorkletConfiguration.default()" in swift:
    raise SystemExit("ios host must not invent BareWorkletConfiguration.default()")

fetch = fetch_path.read_text()
if "--kit" not in fetch:
    raise SystemExit("fetch script must support --kit")
if "android/bare-kit" not in fetch or "ios/BareKit.xcframework" not in fetch:
    raise SystemExit("fetch --kit must extract official android/ios trees")

print("ok BareKit mobile hooks")
print("next (human/CI, cached, sha-pinned, not default PR):")
print("  bash tool/bare/fetch-official-runtime.sh --kit")
print("  bash tool/bare/verify-runtime.sh --kit")
PY
