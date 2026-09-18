import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/local_worklet_bundle.dart';
import 'package:orbits_flutter/transport/worklet_orbits_transport_io.dart'
    show verifyResolvedWorkletTree;

void main() {
  test('shipped worklet manifest matches the local script hash', () {
    final bundle = inspectLocalWorkletBundle();
    expect(bundle.allowsRemoteJs, isFalse);
    expect(bundle.ipc, 'orbits-bare-ipc-v1');
    expect(bundle.hashMatches, isTrue);
    bundle.assertSafeForProduction();
  });

  test('executed worklet tree is verified, not just the CWD sources',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // The shipped tree verifies in place.
    await verifyResolvedWorkletTree(
      File('tool/connectivity_harness/src/worklet.js'),
    );
    // A tampered executed copy fails even when CWD sources are intact.
    final dir = Directory.systemTemp.createTempSync('orbits-exec-bundle-');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final entity
        in Directory('tool/connectivity_harness/src').listSync()) {
      if (entity is File) {
        entity.copySync('${dir.path}/${entity.uri.pathSegments.last}');
      }
    }
    await verifyResolvedWorkletTree(File('${dir.path}/worklet.js'));
    File('${dir.path}/worklet.js')
        .writeAsStringSync('// tampered', mode: FileMode.append);
    await expectLater(
      verifyResolvedWorkletTree(File('${dir.path}/worklet.js')),
      throwsStateError,
    );
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
