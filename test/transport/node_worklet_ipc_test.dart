import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/bare_ipc_client.dart';
import 'package:orbits_flutter/transport/ipc_codec.dart';

void main() {
  test('node worklet answers orbits-bare-ipc-v1 start/stop', () async {
    final script = File('tool/connectivity_harness/src/worklet.js');
    expect(script.existsSync(), isTrue);
    final node = await Process.start(
      'node',
      [script.absolute.path],
    );
    node.stderr.listen((_) {});
    final client = BareIpcClient(write: (bytes) {
      node.stdin.add(bytes);
    });
    node.stdout.listen(client.addBytes);
    addTearDown(() async {
      await client.close();
      node.kill();
    });
    final started = await client
        .request('start', {'peerId': 'ORBIT-AA'})
        .timeout(const Duration(seconds: 8));
    expect(started['port'], isNotNull);
    expect(started['backend'], 'loopback');
    expect(started['noisePublicKey'], isNull);
    final appended = await client.request('journal.append', {
      'fields': {'encryptedEnvelope': 'djI6Y2lwaGVy'},
    }).timeout(const Duration(seconds: 8));
    expect(appended['kind'], 'messageEnvelopeCreated');
    await expectLater(
      client.request('journal.append', {
        'fields': {'plaintext': 'nope', 'encryptedEnvelope': 'x'},
      }),
      throwsA(isA<Object>()),
    );
    final listed = await client
        .request('journal.list')
        .timeout(const Duration(seconds: 8));
    expect((listed['blocks'] as List).length, 1);
    await client.request('stop').timeout(const Duration(seconds: 8));
    expect(kOrbitsBareIpcInfo, 'orbits-bare-ipc-v1');
  });

  test('hyperswarm worklet start without bootstrap is refused', () async {
    final script = File('tool/connectivity_harness/src/worklet.js');
    final node = await Process.start(
      'node',
      [script.absolute.path],
      environment: {
        ...Platform.environment,
        'ORBITS_HARNESS_BACKEND': 'hyperswarm',
      },
    );
    node.stderr.listen((_) {});
    final client = BareIpcClient(write: (bytes) {
      node.stdin.add(bytes);
    });
    node.stdout.listen(client.addBytes);
    addTearDown(() async {
      await client.close();
      node.kill();
    });
    await expectLater(
      client.request('start', {'peerId': 'ORBIT-AA'}).timeout(
        const Duration(seconds: 8),
      ),
      throwsA(isA<Object>()),
    );
  });
}
