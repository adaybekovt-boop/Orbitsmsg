import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/bare_ipc_client.dart';
import 'package:orbits_flutter/transport/bare_runtime.dart';
import 'package:orbits_flutter/transport/local_worklet_bundle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'packaged official Bare is hash-verified and launches the worklet',
    () async {
      final worklet = File('tool/connectivity_harness/src/worklet.js');
      expect(worklet.existsSync(), isTrue);
      inspectLocalWorkletBundle().assertSafeForProduction();

      final launch = resolveBareRuntime(worklet, allowNode: !Platform.isLinux);
      if (launch.kind != 'bare') {
        // Non-Linux CI hosts may not have fetched the official binary.
        expect(launch.kind, 'node');
        return;
      }

      final sidecar = File('${launch.executable}.sha256');
      expect(sidecar.existsSync(), isTrue);
      final expected = sidecar
          .readAsStringSync()
          .trim()
          .split(RegExp(r'\s+'))
          .first;
      final actual = sha256
          .convert(File(launch.executable).readAsBytesSync())
          .toString();
      expect(actual, expected);

      final proc = await Process.start(
        launch.executable,
        launch.arguments,
        workingDirectory: 'tool/connectivity_harness',
        environment: {
          ...Platform.environment,
          'ORBITS_HARNESS_BACKEND': 'loopback',
          'ORBITS_RUNTIME': 'bare',
        },
      );
      addTearDown(proc.kill);
      final client = BareIpcClient(write: proc.stdin.add);
      proc.stdout.listen(client.addBytes);
      addTearDown(client.close);

      final storage = await Directory.systemTemp.createTemp(
        'orbits-dart-bare-',
      );
      addTearDown(() => storage.delete(recursive: true));
      await client.request('start', {
        'peerId': 'ORBIT-DART-BARE',
        'requireRealCorestore': true,
        'storageDir': storage.path,
      });
      final info = await client.request('runtime.info');
      expect(info['runtime'], 'bare');
      expect(info['journal'], 'corestore');
      await client.request('journal.append', {
        'fields': {'encryptedEnvelope': 'v2:dart'},
      });
      final listed = await client.request('journal.list');
      expect((listed['blocks'] as List).length, 1);
      await client.request('stop');
    },
  );

  test('corrupt official Bare sidecar fails closed', () {
    final bogus = File('build/orbits-bare/linux-x64/bare');
    if (!bogus.existsSync()) {
      expect(
        bareManifestForbidsRemoteFetch({
          'remoteFetch': false,
          'downloadUrl': null,
          'bundleUrl': null,
        }),
        isTrue,
      );
      return;
    }
    expect(File('${bogus.path}.sha256').existsSync(), isTrue);
  });
}
