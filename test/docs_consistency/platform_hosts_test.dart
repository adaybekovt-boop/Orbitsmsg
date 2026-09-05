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
      expect(
        RegExp(r'https?://[a-zA-Z0-9]').hasMatch(text),
        isFalse,
        reason: '$path must not embed a fetchable URL',
      );
      expect(text, isNot(contains('fetch(')));
      if (path.endsWith('.kt') || path.endsWith('.swift')) {
        for (final method in const [
          'start',
          'stop',
          'publish',
          'unpublish',
          'connect',
          'disconnect',
          'send',
          'sendFile',
          'suspend',
          'resume',
          'refreshNetwork',
        ]) {
          expect(text, contains(method), reason: '$path missing $method');
        }
        expect(text, contains('REMOTE_JS'), reason: path);
        expect(text, contains('PATH_REQUIRED'), reason: path);
        expect(text, contains('BUNDLE_TAMPERED'), reason: path);
        expect(text, contains('ABI_MISMATCH'), reason: path);
      } else {
        expect(text, contains('orbits_bare_host_start'), reason: path);
        expect(text, contains('orbits_bare_host_send_file'), reason: path);
        expect(text, contains('orbits_bare_host_suspend'), reason: path);
        expect(text, contains('kOrbitsHostBundleTampered'), reason: path);
      }
    }
    expect(
      File('tool/connectivity_harness/src/corestore_journal.js').existsSync(),
      isTrue,
    );
    final journal = File(
      'tool/connectivity_harness/src/corestore_journal.js',
    ).readAsStringSync();
    expect(journal, contains('encryptedEnvelope'));
    expect(journal, contains('plaintext'));
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains('extractBundledWorklet'),
    );
  });

  test('Android/iOS BareKit hosts stay official and URL-free', () {
    const runtimes = <String>[
      'packages/orbits_transport_android/android/src/main/kotlin/app/orbits/transport/OrbitsBareRuntime.kt',
      'packages/orbits_transport_ios/ios/Classes/OrbitsBareRuntime.swift',
      'packages/orbits_transport_macos/macos/Classes/OrbitsBareRuntime.swift',
      'packages/orbits_transport_android/android/build.gradle',
    ];
    for (final path in runtimes) {
      final text = File(path).readAsStringSync();
      expect(
        RegExp(r'https?://[a-zA-Z0-9]').hasMatch(text),
        isFalse,
        reason: '$path must not embed a fetchable URL',
      );
    }
    final android = File(
      'packages/orbits_transport_android/android/src/main/kotlin/app/orbits/transport/OrbitsBareRuntime.kt',
    ).readAsStringSync();
    expect(android, contains('to.holepunch.bare.kit.Worklet'));
    expect(android, contains('StandardCharsets.UTF_8'));
    expect(android, isNot(contains('Redirect.DISCARD')));
    expect(
      android,
      isNot(contains('start.invoke(worklet, "/orbits/worklet.js", source, null)')),
    );
    final ios = File(
      'packages/orbits_transport_ios/ios/Classes/OrbitsBareRuntime.swift',
    ).readAsStringSync();
    expect(ios, contains('canImport(BareKit)'));
    expect(ios, contains('defaultWorkletConfiguration'));
    expect(ios, isNot(contains('BareWorkletConfiguration.default()')));
    final gradle = File(
      'packages/orbits_transport_android/android/build.gradle',
    ).readAsStringSync();
    expect(gradle, contains('classes.jar'));
    expect(gradle, contains('ORBITS_BARE_KIT'));
    expect(gradle, contains('libs/bare-kit'));
    expect(gradle, contains('bare-kit.aar'));
    final pod = File(
      'packages/orbits_transport_ios/ios/orbits_transport_ios.podspec',
    ).readAsStringSync();
    expect(pod, contains('vendored_frameworks'));
    expect(pod, contains('BareKit.xcframework'));
  });
}
