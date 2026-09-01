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
    expect(started['journalBackend'], anyOf('memory', 'fs', 'corestore'));
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

  test('node worklet journalDir round-trips ciphertext after restart', () async {
    final script = File('tool/connectivity_harness/src/worklet.js');
    final dir = Directory.systemTemp.createTempSync('orbits-worklet-journal-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    const cipher = 'djI6am91cm5hbC1yZW9wZW4=';

    Future<Map<String, Object?>> runOnce({
      required bool append,
    }) async {
      final node = await Process.start('node', [script.absolute.path]);
      node.stderr.listen((_) {});
      final client = BareIpcClient(write: node.stdin.add);
      node.stdout.listen(client.addBytes);
      try {
        await client.request('start', {
          'peerId': 'ORBIT-AA',
          'journalDir': dir.path,
        }).timeout(const Duration(seconds: 8));
        if (append) {
          await client.request('journal.append', {
            'fields': {'encryptedEnvelope': cipher},
          }).timeout(const Duration(seconds: 8));
        }
        final listed = await client
            .request('journal.list')
            .timeout(const Duration(seconds: 8));
        await client.request('stop').timeout(const Duration(seconds: 8));
        return listed;
      } finally {
        await client.close();
        node.kill();
        await node.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () => -1,
        );
      }
    }

    final first = await runOnce(append: true);
    expect((first['blocks'] as List).length, 1);
    final second = await runOnce(append: false);
    final blocks = second['blocks'] as List;
    expect(blocks, hasLength(1));
    expect(
      (blocks.first as Map)['fields'],
      containsPair('encryptedEnvelope', cipher),
    );
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

  test('relayThrough without bootstrap still refuses public DHT', () async {
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
      client.request('start', {
        'peerId': 'ORBIT-AA',
        'relayForced': true,
        'relayThrough': [
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ],
      }).timeout(const Duration(seconds: 8)),
      throwsA(isA<Object>()),
    );
  });
}
