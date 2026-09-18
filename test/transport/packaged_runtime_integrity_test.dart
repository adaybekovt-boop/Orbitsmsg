import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/bare_runtime.dart';

void main() {
  test('pins.json forbids runtime fetch and pins official Bare 1.31.0', () {
    final pins =
        jsonDecode(File('tool/bare/pins.json').readAsStringSync()) as Map;
    expect(pins['remoteFetchAtRuntime'], isFalse);
    expect(pins['bareRuntime']['version'], '1.31.0');
    expect(pins['bare']['license'], 'Apache-2.0');
    expect(pins['bareKit']['version'], '2.4.3');
    final artifacts = pins['bareRuntime']['artifacts'] as Map;
    for (final entry in artifacts.entries) {
      final spec = entry.value as Map;
      expect(spec['asset'], isNotEmpty, reason: entry.key.toString());
      expect(
        (spec['sha256'] as String).length,
        64,
        reason: entry.key.toString(),
      );
    }
    expect(
      File('tool/bare/PROVENANCE.md').readAsStringSync(),
      contains('Apache-2.0'),
    );
    final prebuilds = pins['bareKit']['prebuilds'] as Map;
    expect((prebuilds['sha256'] as String).length, 64);
    expect(prebuilds['sha256Source'], 'github-release-asset-digest');
    expect(prebuilds['androidPath'], 'android/bare-kit');
    expect(prebuilds['iosPath'], 'ios/BareKit.xcframework');
    expect(File('tool/bare/link-official-kit.sh').existsSync(), isTrue);
    expect(File('tool/bare/verify-packaged-kit.sh').existsSync(), isTrue);
    expect(File('tool/bare/verify-kit-start.sh').existsSync(), isTrue);
    expect(
      File('tool/bare/verify-kit-start.sh').readAsStringSync(),
      contains('uname -s'),
    );
  });

  test('BareKit mobile hooks verify without downloading prebuilds.zip', () {
    final result = Process.runSync('bash', ['tool/bare/verify-kit-hooks.sh']);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stdout.toString(), contains('ok BareKit mobile hooks'));
    expect(
      result.stdout.toString(),
      contains('bash tool/bare/fetch-official-runtime.sh --kit'),
    );
  });

  test('fetched linux-x64 runtime matches the pinned binary digest', () {
    final binary = File('build/orbits-bare/linux-x64/bare');
    if (!binary.existsSync()) {
      return;
    }
    final digest = sha256.convert(binary.readAsBytesSync()).toString();
    final pins =
        jsonDecode(File('tool/bare/pins.json').readAsStringSync()) as Map;
    expect(
      digest,
      pins['bareRuntime']['artifacts']['linux-x64']['binarySha256'],
    );
    expect(
      bareManifestForbidsRemoteFetch({
        'remoteFetch': false,
        'downloadUrl': null,
        'bundleUrl': null,
      }),
      isTrue,
    );
  });

  test('release resolveBareRuntime does not use Node', () {
    expect(
      () => resolveBareRuntime(
        File('tool/connectivity_harness/src/worklet.js'),
        allowNode: false,
        releaseMode: true,
      ),
      anyOf(returnsNormally, throwsStateError),
    );
    try {
      final launch = resolveBareRuntime(
        File('tool/connectivity_harness/src/worklet.js'),
        allowNode: false,
        releaseMode: true,
      );
      expect(launch.kind, 'bare');
    } on StateError catch (error) {
      expect(error.message, contains('BARE_RUNTIME_MISSING'));
    }
  });
}
