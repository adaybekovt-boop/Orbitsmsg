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

    final sources = Map<String, String>.from(
      (manifest['sources'] as Map).map((k, v) => MapEntry('$k', '$v')),
    );
    expect(sources['worklet.js'], digest);
    final dart = File('lib/transport/worklet_orbits_transport_io.dart')
        .readAsStringSync();
    expect(dart, contains('const _bundledWorkletFiles'));
    for (final name in sources.keys) {
      expect(dart, contains("'$name'"), reason: name);
      final file = File('tool/connectivity_harness/src/$name');
      expect(file.existsSync(), isTrue, reason: name);
      expect(
        sha256.convert(file.readAsBytesSync()).toString(),
        sources[name],
        reason: name,
      );
      final text = file.readAsStringSync();
      expect(text, isNot(contains('fetch(')), reason: name);
    }

    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final name in sources.keys) {
      expect(
        pubspec,
        contains('tool/connectivity_harness/src/$name'),
        reason: name,
      );
    }

    final pkg = File('tool/connectivity_harness/package.json');
    expect(pkg.existsSync(), isTrue);
    final pkgDigest = sha256.convert(pkg.readAsBytesSync()).toString();
    expect(manifest['packageJsonSha256'], pkgDigest);
    final pkgJson = jsonDecode(pkg.readAsStringSync()) as Map;
    expect((pkgJson['imports'] as Map)['node:fs'], containsPair('bare', 'bare-fs'));
  });
}
