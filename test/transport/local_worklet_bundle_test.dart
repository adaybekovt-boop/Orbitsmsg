import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/local_worklet_bundle.dart';

void main() {
  test('shipped worklet manifest matches the local script hash', () {
    final bundle = inspectLocalWorkletBundle();
    expect(bundle.allowsRemoteJs, isFalse);
    expect(bundle.ipc, 'orbits-bare-ipc-v1');
    expect(bundle.hashMatches, isTrue);
    bundle.assertSafeForProduction();
  });

  test('missing or tampered bundle fails closed', () {
    final dir = Directory.systemTemp.createTempSync('orbits-bundle');
    addTearDown(() => dir.deleteSync(recursive: true));
    final manifest = File('${dir.path}/BUNDLE.manifest');
    final script = File('${dir.path}/worklet.js');
    manifest.writeAsStringSync(
      jsonEncode({
        'ipc': 'orbits-bare-ipc-v1',
        'remoteJs': false,
        'workletSha256': 'aa' * 32,
      }),
    );
    expect(
      inspectLocalWorkletBundle(
        manifestPath: manifest.path,
        scriptPath: script.path,
      ).scriptExists,
      isFalse,
    );
    script.writeAsStringSync('console.log(1)');
    final tampered = inspectLocalWorkletBundle(
      manifestPath: manifest.path,
      scriptPath: script.path,
    );
    expect(tampered.hashMatches, isFalse);
    expect(tampered.assertSafeForProduction, throwsStateError);
  });
}
