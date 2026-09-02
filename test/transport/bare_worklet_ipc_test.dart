import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/bare_ipc_client.dart';
import 'package:orbits_flutter/transport/bare_runtime.dart';
import 'package:orbits_flutter/transport/ipc_codec.dart';

void main() {
  test('vendored Bare worklet answers orbits-bare-ipc-v1 start/stop', () async {
    final script = File('tool/connectivity_harness/src/worklet.js');
    expect(script.existsSync(), isTrue);
    final launch = resolveBareRuntime(script);
    if (launch.kind != 'bare') {
      markTestSkipped('vendored Bare + bare-fs not present');
      return;
    }
    final proc = await Process.start(
      launch.executable,
      launch.arguments,
      workingDirectory: script.parent.path,
      environment: {
        ...Platform.environment,
        'ORBITS_HARNESS_BACKEND': 'loopback',
      },
    );
    proc.stderr.listen((_) {});
    final client = BareIpcClient(write: proc.stdin.add);
    proc.stdout.listen(client.addBytes);
    addTearDown(() async {
      await client.close();
      proc.kill();
    });
    final started = await client
        .request('start', {'peerId': 'ORBIT-AA'})
        .timeout(const Duration(seconds: 8));
    expect(started['port'], isNotNull);
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
    final listed =
        await client.request('journal.list').timeout(const Duration(seconds: 8));
    expect((listed['blocks'] as List).length, 1);
    await client.request('stop').timeout(const Duration(seconds: 8));
    expect(kOrbitsBareIpcInfo, 'orbits-bare-ipc-v1');
    expect(kBareBinaryShipped, isFalse);
  });

  test('Bare worklet journalDir hydrates ciphertext after restart', () async {
    final script = File('tool/connectivity_harness/src/worklet.js');
    final launch = resolveBareRuntime(script);
    if (launch.kind != 'bare') {
      markTestSkipped('vendored Bare + bare-fs not present');
      return;
    }
    final dir = Directory.systemTemp.createTempSync('orbits-bare-journal-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    const cipher = 'djI6YmFyZS1qb3VybmFs';

    Future<Map<String, Object?>> runOnce({required bool append}) async {
      final proc = await Process.start(
        launch.executable,
        launch.arguments,
        workingDirectory: script.parent.path,
        environment: {
          ...Platform.environment,
          'ORBITS_HARNESS_BACKEND': 'loopback',
        },
      );
      proc.stderr.listen((_) {});
      final client = BareIpcClient(write: proc.stdin.add);
      proc.stdout.listen(client.addBytes);
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
        final listed =
            await client.request('journal.list').timeout(const Duration(seconds: 8));
        await client.request('stop').timeout(const Duration(seconds: 8));
        return listed;
      } finally {
        await client.close();
        proc.kill();
        await proc.exitCode.timeout(
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
    expect(kBareBinaryShipped, isFalse);
  });
}
