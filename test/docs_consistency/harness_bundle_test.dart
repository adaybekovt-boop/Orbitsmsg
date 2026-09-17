import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('harness bundle forbids remote JS and pins the worklet hash', () {
    final manifest = jsonDecode(
      File('tool/connectivity_harness/BUNDLE.manifest').readAsStringSync(),
    ) as Map;
    expect(manifest['remoteJs'], isFalse);
    expect(manifest['ipc'], 'orbits-bare-ipc-v1');

    final worklet = File('tool/connectivity_harness/src/worklet.js');
    expect(worklet.existsSync(), isTrue);
    final source = worklet.readAsStringSync();
    expect(source, isNot(contains('http://')));
    expect(source, isNot(contains('https://')));
    expect(source, isNot(contains('fetch(')));

    final digest = sha256.convert(worklet.readAsBytesSync()).toString();
    expect(digest, hasLength(64));
    expect(manifest['workletSha256'], digest);
    expect(source, contains("require('./incoming_paths')"));
    expect(source, isNot(contains("require('./stand')")));

    final files = Map<String, Object?>.from(manifest['files'] as Map);
    expect(files['incoming_paths.js'], isNotNull);
    expect(files['stand.js'], isNotNull);
    expect(files['corestore_journal.js'], digestOf('corestore_journal.js'));

    final android = File(
      'packages/orbits_transport_android/android/src/main/kotlin/app/orbits/transport/OrbitsBareRuntime.kt',
    ).readAsStringSync();
    final ios = File(
      'packages/orbits_transport_ios/ios/Classes/OrbitsBareRuntime.swift',
    ).readAsStringSync();
    final desktop = File(
      'lib/transport/worklet_orbits_transport_io.dart',
    ).readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final text in [android, ios, desktop, pubspec]) {
      expect(text, contains('incoming_paths.js'));
      expect(text, isNot(contains('stand.js')));
    }
  });
}

String digestOf(String name) {
  return sha256
      .convert(
        File('tool/connectivity_harness/src/$name').readAsBytesSync(),
      )
      .toString();
}
