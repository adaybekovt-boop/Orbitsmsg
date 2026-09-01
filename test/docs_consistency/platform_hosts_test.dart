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
      expect(text, contains('barePath'), reason: path);
      expect(text, contains('://'), reason: path);
      expect(text, isNot(contains('http://')));
      expect(text, isNot(contains('https://')));
    }
    expect(
      File('packages/orbits_transport_linux/linux/orbits_transport_plugin.cc')
          .readAsStringSync(),
      contains('orbits_transport_plugin_register_with_registrar'),
    );
    expect(
      File(
        'packages/orbits_transport_linux/linux/include/orbits_transport_linux/orbits_transport_plugin.h',
      ).existsSync(),
      isTrue,
    );
    expect(
      File('packages/orbits_transport_windows/windows/orbits_transport_plugin.cpp')
          .readAsStringSync(),
      contains('OrbitsTransportPluginRegisterWithRegistrar'),
    );
    expect(
      File(
        'packages/orbits_transport_windows/windows/include/orbits_transport_windows/orbits_transport_plugin.h',
      ).existsSync(),
      isTrue,
    );
    expect(
      File('tool/connectivity_harness/src/corestore_journal.js').existsSync(),
      isTrue,
    );
    final journal =
        File('tool/connectivity_harness/src/corestore_journal.js').readAsStringSync();
    expect(journal, contains('encryptedEnvelope'));
    expect(journal, contains('plaintext'));
    expect(journal, contains('useCorestoreIfPresent'));
    expect(journal, contains('Bare.Addon.load'));
    expect(journal, contains('envelopes.jsonl'));
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
      File('packages/orbits_transport_linux/linux/CMakeLists.txt')
          .readAsStringSync(),
      contains('configure_file'),
    );
    expect(
      File('packages/orbits_transport_linux/linux/CMakeLists.txt')
          .readAsStringSync(),
      contains('CMAKE_CURRENT_BINARY_DIR}/bare'),
    );
    expect(
      File('packages/orbits_transport_linux/linux/CMakeLists.txt')
          .readAsStringSync(),
      contains('../../../tool/bare/linux-x64/bare'),
    );
    expect(
      File('packages/orbits_transport_linux/linux/CMakeLists.txt')
          .readAsStringSync(),
      isNot(contains('../../../../tool/bare')),
    );
    expect(
      File('packages/orbits_transport_windows/windows/CMakeLists.txt')
          .readAsStringSync(),
      isNot(contains('http')),
    );
    expect(
      File('packages/orbits_transport_windows/windows/CMakeLists.txt')
          .readAsStringSync(),
      contains('CMAKE_CURRENT_BINARY_DIR}/bare.exe'),
    );
    expect(
      File('packages/orbits_transport_windows/windows/CMakeLists.txt')
          .readAsStringSync(),
      contains('../../../tool/bare/windows-x64/bare.exe'),
    );
    expect(
      File('packages/orbits_transport_android/android/build.gradle')
          .readAsStringSync(),
      contains('../../../tool/bare/android-arm64/bare'),
    );
    expect(
      File('packages/orbits_transport_android/android/build.gradle')
          .readAsStringSync(),
      contains('copyOrbitsBareAsset'),
    );
    expect(
      File('packages/orbits_transport_android/android/build.gradle')
          .readAsStringSync(),
      isNot(contains('../../../../tool/bare')),
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
    expect(ci, contains('flutter build linux --release'));
    expect(ci, contains('Build Linux'));
    expect(ci, contains('bundle/lib/bare'));
    expect(ci, contains('runner/Release/bare.exe'));
    expect(ci, contains('assets/bare'));
    expect(ci, contains("find build/ios/iphoneos/Runner.app -name 'bare'"));
    expect(
      File('linux/flutter/generated_plugin_registrant.cc').readAsStringSync(),
      contains('orbits_transport_plugin_register_with_registrar'),
    );
    expect(
      File('windows/flutter/generated_plugin_registrant.cc').readAsStringSync(),
      contains('OrbitsTransportPluginRegisterWithRegistrar'),
    );
    expect(ci, contains('flutter build macos --release'));
    expect(
      File('macos/Flutter/GeneratedPluginRegistrant.swift').readAsStringSync(),
      contains('OrbitsTransportPlugin.register'),
    );
  });
}