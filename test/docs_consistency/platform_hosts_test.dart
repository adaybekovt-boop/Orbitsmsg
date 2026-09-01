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
    expect(journal, contains('useCorestoreIfPresent'));
    expect(
      File('tool/connectivity_harness/src/worklet.js').readAsStringSync(),
      contains('useCorestoreIfPresent'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains('extractBundledWorklet'),
    );
    expect(
      File('packages/orbits_transport_linux/linux/CMakeLists.txt').existsSync(),
      isTrue,
    );
    expect(
      File('packages/orbits_transport_linux/linux/CMakeLists.txt')
          .readAsStringSync(),
      isNot(contains('http')),
    );
    expect(
      File('packages/orbits_transport_linux/linux/CMakeLists.txt')
          .readAsStringSync(),
      contains('linux-arm64'),
    );
    expect(
      File('packages/orbits_transport_windows/windows/CMakeLists.txt')
          .readAsStringSync(),
      isNot(contains('http')),
    );

    final appPub = File('pubspec.yaml').readAsStringSync();
    expect(appPub, contains('path: packages/orbits_transport'));
    expect(appPub, contains('PWA stays on PeerJS'));

    final facade = File('packages/orbits_transport/pubspec.yaml').readAsStringSync();
    expect(facade, contains('default_package: orbits_transport_android'));
    expect(facade, contains('default_package: orbits_transport_ios'));
    expect(facade, contains('default_package: orbits_transport_linux'));
    expect(facade, contains('default_package: orbits_transport_macos'));
    expect(facade, contains('default_package: orbits_transport_windows'));
    expect(facade, isNot(contains('default_package: orbits_transport_web')));
    expect(
      facade.contains(RegExp(r'^\s+web:', multiLine: true)),
      isFalse,
    );

    final ci = File('.github/workflows/build.yml').readAsStringSync();
    expect(ci, contains('tool/bare/embed.sh linux-x64'));
    expect(ci, contains('tool/bare/embed.sh ios-arm64'));
    expect(ci, contains('tool/bare/embed.sh darwin-arm64'));
    expect(ci, contains('tool/bare/embed.sh android-arm64'));
    expect(ci, contains('tool/bare/embed.sh windows-x64'));
    expect(ci, contains('tool/bare/vendor.sh linux-arm64'));
    expect(ci, contains('tool/bare/vendor.sh darwin-x64'));
    expect(ci, contains('bare-arm64'));
    expect(ci, contains('bare-x64'));
    expect(ci, isNot(contains('tool/bare/embed.sh linux-arm64')));
    expect(ci, isNot(contains('tool/bare/embed.sh darwin-x64')));
    expect(ci, contains('kBareBinaryShipped stays false'));
  });
}