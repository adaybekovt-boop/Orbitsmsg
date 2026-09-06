#!/usr/bin/env python3
"""
Assembles iOS .xcframework bundles for all native addons required by
Hyperswarm and Corestore, ensuring ahead-of-time linking and zero
unsigned code loading from writable storage.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

def main():
    root = Path(__file__).resolve().parent.parent.parent
    harness_nm = root / 'tool' / 'connectivity_harness' / 'node_modules'
    ios_dir = root / 'packages' / 'orbits_transport_ios' / 'ios'

    addons = [
        'udx-native',
        'sodium-native',
        'quickbit-native',
        'simdle-native',
        'bare-url',
        'fs-native-extensions'
    ]

    lipo_bin = shutil.which('lipo')

    for name in addons:
        prebuilds = harness_nm / name / 'prebuilds'
        arm64_src = prebuilds / 'ios-arm64' / f'{name}.bare'
        sim_arm64_src = prebuilds / 'ios-arm64-simulator' / f'{name}.bare'
        sim_x64_src = prebuilds / 'ios-x64-simulator' / f'{name}.bare'

        if not arm64_src.exists():
            print(f'ERROR: missing {arm64_src}', file=sys.stderr)
            sys.exit(1)

        xcframework_dir = ios_dir / f'{name}.xcframework'
        if xcframework_dir.exists():
            shutil.rmtree(xcframework_dir)

        arm64_fw = xcframework_dir / 'ios-arm64' / f'{name}.framework'
        sim_multi_fw = xcframework_dir / 'ios-arm64_x86_64-simulator' / f'{name}.framework'
        sim_fw = xcframework_dir / 'ios-arm64-simulator' / f'{name}.framework'

        arm64_fw.mkdir(parents=True, exist_ok=True)
        sim_multi_fw.mkdir(parents=True, exist_ok=True)
        sim_fw.mkdir(parents=True, exist_ok=True)

        shutil.copy2(arm64_src, arm64_fw / name)

        # Prepare simulator binary (universal if lipo available, else best available)
        sim_created = False
        if lipo_bin and sim_arm64_src.exists() and sim_x64_src.exists():
            res = subprocess.run(
                [lipo_bin, '-create', str(sim_arm64_src), str(sim_x64_src), '-output', str(sim_multi_fw / name)],
                capture_output=True,
                text=True
            )
            if res.returncode == 0:
                sim_created = True

        if not sim_created:
            chosen = sim_arm64_src if sim_arm64_src.exists() else sim_x64_src
            if chosen.exists():
                shutil.copy2(chosen, sim_multi_fw / name)

        # Mirror simulator framework to ios-arm64-simulator as well
        shutil.copy2(sim_multi_fw / name, sim_fw / name)

        fw_plist = f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleDevelopmentRegion</key>
\t<string>en</string>
\t<key>CFBundleExecutable</key>
\t<string>{name}</string>
\t<key>CFBundleIdentifier</key>
\t<string>to.holepunch.{name}</string>
\t<key>CFBundleInfoDictionaryVersion</key>
\t<string>6.0</string>
\t<key>CFBundleName</key>
\t<string>{name}</string>
\t<key>CFBundlePackageType</key>
\t<string>FMWK</string>
\t<key>CFBundleShortVersionString</key>
\t<string>1.0.0</string>
\t<key>CFBundleVersion</key>
\t<string>1.0.0</string>
\t<key>MinimumOSVersion</key>
\t<string>13.0</string>
</dict>
</plist>
'''
        (arm64_fw / 'Info.plist').write_text(fw_plist, encoding='utf-8')
        (sim_multi_fw / 'Info.plist').write_text(fw_plist, encoding='utf-8')
        (sim_fw / 'Info.plist').write_text(fw_plist, encoding='utf-8')

        xc_plist = f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>AvailableLibraries</key>
\t<array>
\t\t<dict>
\t\t\t<key>BinaryPath</key>
\t\t\t<string>{name}.framework/{name}</string>
\t\t\t<key>LibraryIdentifier</key>
\t\t\t<string>ios-arm64_x86_64-simulator</string>
\t\t\t<key>LibraryPath</key>
\t\t\t<string>{name}.framework</string>
\t\t\t<key>SupportedArchitectures</key>
\t\t\t<array>
\t\t\t\t<string>arm64</string>
\t\t\t\t<string>x86_64</string>
\t\t\t</array>
\t\t\t<key>SupportedPlatform</key>
\t\t\t<string>ios</string>
\t\t\t<key>SupportedPlatformVariant</key>
\t\t\t<string>simulator</string>
\t\t</dict>
\t\t<dict>
\t\t\t<key>BinaryPath</key>
\t\t\t<string>{name}.framework/{name}</string>
\t\t\t<key>LibraryIdentifier</key>
\t\t\t<string>ios-arm64</string>
\t\t\t<key>LibraryPath</key>
\t\t\t<string>{name}.framework</string>
\t\t\t<key>SupportedArchitectures</key>
\t\t\t<array>
\t\t\t\t<string>arm64</string>
\t\t\t</array>
\t\t\t<key>SupportedPlatform</key>
\t\t\t<string>ios</string>
\t\t</dict>
\t</array>
\t<key>CFBundlePackageType</key>
\t<string>XFWK</string>
\t<key>XCFrameworkFormatVersion</key>
\t<string>1.0</string>
</dict>
</plist>
'''
        (xcframework_dir / 'Info.plist').write_text(xc_plist, encoding='utf-8')
        print(f'ok assembled {name}.xcframework -> {xcframework_dir}')

if __name__ == '__main__':
    main()
