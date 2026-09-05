#!/usr/bin/env bash
# Assemble the on-device worklet tree (src + production node_modules).
# Does not fetch remote JS. Requires a prior npm ci in the harness.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="$ROOT/tool/connectivity_harness"
STAGE="$ROOT/build/orbits-bare/mobile-worklet"
ZIP="$ROOT/build/orbits-bare/mobile-worklet.zip"
IOS_ZIP="$ROOT/packages/orbits_transport_ios/ios/orbits-worklet-modules.zip"

if [[ ! -f "$HARNESS/src/worklet.js" ]]; then
  echo "BARE_WORKLET_FAILED: missing $HARNESS/src/worklet.js" >&2
  exit 1
fi
if [[ ! -d "$HARNESS/node_modules/hyperswarm" ]]; then
  echo "BARE_WORKLET_FAILED: run npm ci --prefix tool/connectivity_harness first" >&2
  exit 1
fi
for addon in \
  "$HARNESS/node_modules/udx-native/prebuilds/android-arm64/udx-native.bare" \
  "$HARNESS/node_modules/udx-native/prebuilds/ios-arm64/udx-native.bare"
do
  if [[ ! -f "$addon" ]]; then
    echo "BARE_WORKLET_FAILED: missing mobile addon $addon" >&2
    exit 1
  fi
done

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$HARNESS/src/." "$STAGE/"
cp -a "$HARNESS/package.json" "$STAGE/package.json"
cp -a "$HARNESS/node_modules" "$STAGE/node_modules"

# Android zip keeps everything required by Android
rm -f "$ZIP"
rm -f "$IOS_ZIP"

if command -v zip >/dev/null 2>&1; then
  (
    cd "$STAGE"
    zip -qr "$ZIP" .
  )
  (
    cd "$STAGE"
    zip -qr "$IOS_ZIP" . -x "*.bare" "*.node" "*.dylib" "*.so"
  )
else
  PYTHON_BIN="python3"
  if ! command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python"
  fi
  "$PYTHON_BIN" - "$STAGE" "$ZIP" "$IOS_ZIP" <<'PY'
import os
import sys
import zipfile

stage, android_zip, ios_zip = sys.argv[1:4]
exclude = {".bare", ".node", ".dylib", ".so"}

with zipfile.ZipFile(android_zip, 'w', zipfile.ZIP_DEFLATED) as za, \
     zipfile.ZipFile(ios_zip, 'w', zipfile.ZIP_DEFLATED) as zi:
    for root, dirs, files in os.walk(stage):
        for f in sorted(files):
            p = os.path.join(root, f)
            rel = os.path.relpath(p, stage).replace("\\", "/")
            za.write(p, rel)
            _, ext = os.path.splitext(f)
            if ext.lower() not in exclude:
                zi.write(p, rel)
PY
fi

# Assemble udx-native.xcframework for iOS signed framework linking
IOS_DIR="$ROOT/packages/orbits_transport_ios/ios"
UDX_PREBUILDS="$HARNESS/node_modules/udx-native/prebuilds"
UDX_XCFRAMEWORK="$IOS_DIR/udx-native.xcframework"

if [[ -f "$UDX_PREBUILDS/ios-arm64/udx-native.bare" ]]; then
  rm -rf "$UDX_XCFRAMEWORK"
  mkdir -p "$UDX_XCFRAMEWORK/ios-arm64/udx-native.framework"
  mkdir -p "$UDX_XCFRAMEWORK/ios-arm64-simulator/udx-native.framework"

  # Device slice
  cp -a "$UDX_PREBUILDS/ios-arm64/udx-native.bare" "$UDX_XCFRAMEWORK/ios-arm64/udx-native.framework/udx-native"
  cat > "$UDX_XCFRAMEWORK/ios-arm64/udx-native.framework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>udx-native</string>
	<key>CFBundleIdentifier</key>
	<string>to.holepunch.udx-native</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>udx-native</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.21.1</string>
	<key>CFBundleVersion</key>
	<string>1.21.1</string>
	<key>MinimumOSVersion</key>
	<string>13.0</string>
</dict>
</plist>
PLIST

  # Simulator slice
  sim_src="$UDX_PREBUILDS/ios-arm64-simulator/udx-native.bare"
  if [[ ! -f "$sim_src" ]]; then
    sim_src="$UDX_PREBUILDS/ios-x64-simulator/udx-native.bare"
  fi
  cp -a "$sim_src" "$UDX_XCFRAMEWORK/ios-arm64-simulator/udx-native.framework/udx-native"
  cat > "$UDX_XCFRAMEWORK/ios-arm64-simulator/udx-native.framework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>udx-native</string>
	<key>CFBundleIdentifier</key>
	<string>to.holepunch.udx-native</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>udx-native</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.21.1</string>
	<key>CFBundleVersion</key>
	<string>1.21.1</string>
	<key>MinimumOSVersion</key>
	<string>13.0</string>
</dict>
</plist>
PLIST

  # XCFramework Info.plist
  cat > "$UDX_XCFRAMEWORK/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>udx-native.framework/udx-native</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64-simulator</string>
			<key>LibraryPath</key>
			<string>udx-native.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
			<key>SupportedPlatformVariant</key>
			<string>simulator</string>
		</dict>
		<dict>
			<key>BinaryPath</key>
			<string>udx-native.framework/udx-native</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64</string>
			<key>LibraryPath</key>
			<string>udx-native.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST
fi

echo "ok mobile worklet zip $(wc -c < "$ZIP") bytes -> $ZIP"
echo "ok copied iOS worklet zip (binaries excluded) -> $IOS_ZIP"
if [[ -f "$ROOT/tool/bare/assemble_ios_addons.py" ]]; then
  PYTHON_BIN="python3"
  if ! command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python"
  fi
  "$PYTHON_BIN" "$ROOT/tool/bare/assemble_ios_addons.py"
fi

