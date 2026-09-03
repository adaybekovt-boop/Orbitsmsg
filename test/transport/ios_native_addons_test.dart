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
      final nameBytes = bytes.sublist(i + 46, i + 46 + nameLen);
      names.add(String.fromCharCodes(nameBytes));
      i += 46 + nameLen + extraLen + commentLen - 1;
    }
  }
  return names;
}

void main() {
  setUpAll(() {
    final harness = Directory('tool/connectivity_harness/node_modules');
    if (harness.existsSync()) {
      final script = File('tool/bare/assemble_ios_addons.py');
      if (script.existsSync()) {
        try {
          Process.runSync('python3', [script.path]);
        } catch (_) {
          try {
            Process.runSync('python', [script.path]);
          } catch (_) {}
        }
      }
    }
  });

  const requiredAddons = [
    'udx-native',
    'sodium-native',
    'quickbit-native',
    'simdle-native',
    'bare-url',
    'fs-native-extensions',
  ];

  test('every Hyperswarm/Corestore native addon is packaged as iOS xcframework', () {
    final iosDir = Directory('packages/orbits_transport_ios/ios');
    expect(iosDir.existsSync(), isTrue, reason: 'iOS plugin dir must exist');

    for (final addon in requiredAddons) {
      final xcframework = Directory('${iosDir.path}/$addon.xcframework');
      expect(
        xcframework.existsSync(),
        isTrue,
        reason: '$addon.xcframework must be present in packages/orbits_transport_ios/ios',
      );

      final xcPlist = File('${xcframework.path}/Info.plist');
      expect(xcPlist.existsSync(), isTrue);
      final xcPlistContent = xcPlist.readAsStringSync();
      expect(xcPlistContent, contains('AvailableLibraries'));
      expect(xcPlistContent, contains('ios-arm64'));
      expect(xcPlistContent, contains('ios-arm64-simulator'));

      final arm64Fw = Directory('${xcframework.path}/ios-arm64/$addon.framework');
      expect(arm64Fw.existsSync(), isTrue);
      expect(File('${arm64Fw.path}/$addon').existsSync(), isTrue);
      expect(File('${arm64Fw.path}/Info.plist').existsSync(), isTrue);

      final simFw = Directory('${xcframework.path}/ios-arm64-simulator/$addon.framework');
      expect(simFw.existsSync(), isTrue);
      expect(File('${simFw.path}/$addon').existsSync(), isTrue);
      expect(File('${simFw.path}/Info.plist').existsSync(), isTrue);
    }
  });

  test('iOS podspec vendors all xcframeworks ahead of time', () {
    final podspec = File('packages/orbits_transport_ios/ios/orbits_transport_ios.podspec');
    expect(podspec.existsSync(), isTrue);
    final content = podspec.readAsStringSync();
    expect(content, contains('s.vendored_frameworks'));
    expect(content, contains('Dir.glob(File.join(__dir__, \'*.xcframework\'))'));
  });

  test('iOS worklet modules zip contains no unsigned native binaries', () {
    final zipFile = File('packages/orbits_transport_ios/ios/orbits-worklet-modules.zip');
    if (zipFile.existsSync()) {
      final bytes = zipFile.readAsBytesSync();
      final names = _readZipEntryNames(bytes);
      final forbiddenExts = ['.bare', '.node', '.dylib', '.so'];
      for (final name in names) {
        for (final ext in forbiddenExts) {
          expect(
            name.toLowerCase().endsWith(ext),
            isFalse,
            reason: 'iOS worklet zip must not contain native binary $name',
          );
        }
      }
    }
  });
}
