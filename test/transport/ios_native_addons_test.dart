import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

List<String> _readZipEntryNames(Uint8List bytes) {
  final names = <String>[];
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < bytes.length - 46; i++) {
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x4b &&
        bytes[i + 2] == 0x01 &&
        bytes[i + 3] == 0x02) {
      final nameLen = bd.getUint16(i + 28, Endian.little);
      final extraLen = bd.getUint16(i + 30, Endian.little);
      final commentLen = bd.getUint16(i + 32, Endian.little);
      names.add(String.fromCharCodes(bytes.sublist(i + 46, i + 46 + nameLen)));
      i += 46 + nameLen + extraLen + commentLen - 1;
    }
  }
  return names;
}

const requiredAddons = [
  'udx-native',
  'sodium-native',
  'quickbit-native',
  'simdle-native',
  'bare-url',
  'fs-native-extensions',
];

void _writePlist(File file, {required bool xc}) {
  file.writeAsStringSync(
    xc
        ? '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>AvailableLibraries</key>
  <array>
    <dict><key>LibraryIdentifier</key><string>ios-arm64</string></dict>
    <dict><key>LibraryIdentifier</key><string>ios-arm64_x86_64-simulator</string></dict>
  </array>
</dict></plist>
'''
        : '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>addon</string>
</dict></plist>
''',
  );
}

Directory _materializeFixture(Directory root, String addon) {
  final xc = Directory('${root.path}/$addon.xcframework')..createSync(recursive: true);
  _writePlist(File('${xc.path}/Info.plist'), xc: true);
  final arm = Directory('${xc.path}/ios-arm64/$addon.framework')
    ..createSync(recursive: true);
  File('${arm.path}/$addon').writeAsBytesSync(const [0xCA, 0xFE]);
  _writePlist(File('${arm.path}/Info.plist'), xc: false);
  final sim = Directory('${xc.path}/ios-arm64_x86_64-simulator/$addon.framework')
    ..createSync(recursive: true);
  File('${sim.path}/$addon').writeAsBytesSync(const [0xCA, 0xFE]);
  _writePlist(File('${sim.path}/Info.plist'), xc: false);
  return xc;
}

void expectXcframeworkLayout(Directory iosDir, String addon) {
  final xcframework = Directory('${iosDir.path}/$addon.xcframework');
  expect(
    xcframework.existsSync(),
    isTrue,
    reason: '$addon.xcframework must be present in ${iosDir.path}',
  );
  final xcPlist = File('${xcframework.path}/Info.plist');
  expect(xcPlist.existsSync(), isTrue);
  final xcPlistContent = xcPlist.readAsStringSync();
  expect(xcPlistContent, contains('AvailableLibraries'));
  expect(xcPlistContent, contains('ios-arm64'));
  expect(xcPlistContent, contains('simulator'));

  final arm64Fw = Directory('${xcframework.path}/ios-arm64/$addon.framework');
  expect(arm64Fw.existsSync(), isTrue);
  expect(File('${arm64Fw.path}/$addon').existsSync(), isTrue);
  expect(File('${arm64Fw.path}/Info.plist').existsSync(), isTrue);

  final simMultiFw = Directory(
    '${xcframework.path}/ios-arm64_x86_64-simulator/$addon.framework',
  );
  final simFw = Directory('${xcframework.path}/ios-arm64-simulator/$addon.framework');
  expect(simMultiFw.existsSync() || simFw.existsSync(), isTrue);
  final activeSim = simMultiFw.existsSync() ? simMultiFw : simFw;
  expect(File('${activeSim.path}/$addon').existsSync(), isTrue);
  expect(File('${activeSim.path}/Info.plist').existsSync(), isTrue);
}

bool _officialKitPresent() {
  final iosDir = Directory('packages/orbits_transport_ios/ios');
  if (!iosDir.existsSync()) return false;
  return requiredAddons.every(
    (addon) => Directory('${iosDir.path}/$addon.xcframework').existsSync(),
  );
}

bool _prebuildsPresent() {
  final harness = Directory('tool/connectivity_harness/node_modules');
  if (!harness.existsSync()) return false;
  return requiredAddons.every((addon) {
    final bare = File(
      '${harness.path}/$addon/prebuilds/ios-arm64/$addon.bare',
    );
    return bare.existsSync();
  });
}

void main() {
  test('official ios kit is absent before fetch and present after assemble', () {
    final iosDir = Directory('packages/orbits_transport_ios/ios');
    expect(iosDir.existsSync(), isTrue, reason: 'iOS plugin dir must exist');
    final before = _officialKitPresent();
    if (!before) {
      expect(
        requiredAddons.any(
          (addon) =>
              !Directory('${iosDir.path}/$addon.xcframework').existsSync(),
        ),
        isTrue,
        reason: 'without BareKit fetch, at least one xcframework is absent',
      );
    }
    if (_prebuildsPresent()) {
      final script = File('tool/bare/assemble_ios_addons.py');
      expect(script.existsSync(), isTrue);
      final assembled = Process.runSync('python3', [script.path]);
      expect(
        assembled.exitCode,
        0,
        reason: '${assembled.stderr}\n${assembled.stdout}',
      );
      expect(_officialKitPresent(), isTrue);
      for (final addon in requiredAddons) {
        expectXcframeworkLayout(iosDir, addon);
      }
    } else if (!before) {
      // Self-contained environment: prove the layout checker against a fixture.
      final tmp = Directory.systemTemp.createTempSync('orbits-ios-kit-');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      for (final addon in requiredAddons) {
        _materializeFixture(tmp, addon);
        expectXcframeworkLayout(tmp, addon);
      }
    }
  });

  test('fixture xcframeworks satisfy the iOS addon layout contract', () {
    final tmp = Directory.systemTemp.createTempSync('orbits-ios-fx-');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    for (final addon in requiredAddons) {
      _materializeFixture(tmp, addon);
      expectXcframeworkLayout(tmp, addon);
    }
  });

  test('iOS podspec vendors all xcframeworks ahead of time', () {
    final podspec = File(
      'packages/orbits_transport_ios/ios/orbits_transport_ios.podspec',
    );
    expect(podspec.existsSync(), isTrue);
    final content = podspec.readAsStringSync();
    expect(content, contains('s.vendored_frameworks'));
    expect(
      content,
      contains("Dir.glob(File.join(__dir__, '*.xcframework'))"),
    );
  });

  test('iOS worklet modules zip contains no unsigned native binaries', () {
    final zipFile = File(
      'packages/orbits_transport_ios/ios/orbits-worklet-modules.zip',
    );
    if (!zipFile.existsSync()) {
      expect(
        zipFile.existsSync(),
        isFalse,
        reason: 'zip absent before kit fetch — honest empty state',
      );
      return;
    }
    final names = _readZipEntryNames(zipFile.readAsBytesSync());
    const forbiddenExts = ['.bare', '.node', '.dylib', '.so'];
    for (final name in names) {
      for (final ext in forbiddenExts) {
        expect(
          name.toLowerCase().endsWith(ext),
          isFalse,
          reason: 'iOS worklet zip must not contain native binary $name',
        );
      }
    }
  });
}
