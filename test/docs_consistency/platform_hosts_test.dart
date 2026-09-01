import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every OS host refuses remote Bare JS and ships a local plugin', () {
    const hosts = <String>[
      'packages/orbits_transport_android/android/src/main/kotlin/app/orbits/transport/OrbitsTransportPlugin.kt',
      'packages/orbits_transport_ios/ios/Classes/OrbitsTransportPlugin.swift',
      'packages/orbits_transport_macos/macos/Classes/OrbitsTransportPlugin.swift',
      'packages/orbits_transport_windows/windows/orbits_transport_plugin.cpp',
      'packages/orbits_transport_linux/linux/orbits_transport_plugin.cc',
    ];
    for (final path in hosts) {
      final text = File(path).readAsStringSync();
      expect(text, contains('must not fetch remote JS'), reason: path);
      expect(text, isNot(contains('http://')));
      expect(text, isNot(contains('https://')));
    }
    expect(
      File('tool/connectivity_harness/src/corestore_journal.js').existsSync(),
      isTrue,
    );
    final journal =
        File('tool/connectivity_harness/src/corestore_journal.js').readAsStringSync();
    expect(journal, contains('encryptedEnvelope'));
    expect(journal, contains('plaintext'));
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains('extractBundledWorklet'),
    );
  });
}