import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/bare_ipc_client.dart';
import 'package:orbits_flutter/transport/ipc_codec.dart';

void main() {
  test('in-process IPC start/suspend/resume/stop', () async {
    final pair = openInProcessIpc();
    expect(kOrbitsBareIpcInfo, 'orbits-bare-ipc-v1');
    await pair.client.request('start', {'peerId': 'ORBIT-AA'});
    expect(pair.worklet.started, isTrue);
    await pair.client.request('publish', {
      'binding': {'deviceId': 'dev-a'},
    });
    expect(pair.worklet.published, isTrue);
    await pair.client.request('suspend');
    expect(pair.worklet.suspended, isTrue);
    await expectLater(pair.client.request('send'), throwsStateError);
    await pair.client.request('resume');
    await pair.client.request('stop');
    expect(pair.worklet.started, isFalse);
    expect(pair.worklet.methods, containsAll(['start', 'suspend', 'resume', 'stop']));
    await pair.client.close();
  });

  test('in-process IPC rememberPeer journal and autobase succeed', () async {
    final pair = openInProcessIpc();
    await pair.client.request('rememberPeer', {
      'peerId': 'ORBIT-BB',
      'noisePublicKey': 'aa',
    });
    expect(pair.worklet.rememberedPeers, isNotEmpty);
    expect(pair.worklet.rememberedPeers.last['peerId'], 'ORBIT-BB');

    final appended = await pair.client.request('journal.append', {
      'fields': {'encryptedEnvelope': 'djI6Y2lwaGVy'},
    });
    expect(appended['fields'], isA<Map>());
    expect(
      (appended['fields'] as Map)['encryptedEnvelope'],
      'djI6Y2lwaGVy',
    );

    final listed = await pair.client.request('journal.list');
    expect(listed['blocks'], isA<List>());
    expect((listed['blocks'] as List).length, 1);

    final hydrated = await pair.client.request('autobase.hydrate');
    expect(hydrated['hydrated'], isTrue);

    final state = await pair.client.request('autobase.state');
    expect(state, isA<Map<String, Object?>>());
    expect(pair.worklet.methods, containsAll([
      'rememberPeer',
      'journal.append',
      'journal.list',
      'autobase.hydrate',
      'autobase.state',
    ]));
    await pair.client.close();
  });

  test('in-process IPC disconnect succeeds after start', () async {
    final pair = openInProcessIpc();
    await pair.client.request('start', {'peerId': 'ORBIT-AA'});
    await pair.client.request('disconnect', {'peerId': 'ORBIT-BB'});
    expect(pair.worklet.methods, contains('disconnect'));
    await pair.client.close();
  });

  test(
    'worklet error IPC maps file-hash to TransportError',
    () async {
      final pair = openInProcessIpc();
      final seen = <Map<String, Object?>>[];
      final sub = pair.client.events.listen(seen.add);
      pair.client.addBytes(
        OrbitsIpcCodec.encode(
          OrbitsIpcMessage(
            type: kIpcEvent,
            body: <String, Object?>{
              'name': 'error',
              'payload': <String, Object?>{
                'code': 'file-hash',
                'message': 'attach hash mismatch',
              },
            },
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen, isNotEmpty);
      expect(seen.first['name'], 'error');
      expect(
        (seen.first['payload'] as Map?)?['code'],
        'file-hash',
      );
      await sub.cancel();
      await pair.client.close();

      final src = File('lib/transport/worklet_orbits_transport_io.dart')
          .readAsStringSync();
      final handler = src.split('void _onIpcEvent')[1];
      final errorCase = handler.indexOf("case 'error'");
      final transportError = handler.indexOf('TransportError');
      final defaultCase = handler.indexOf('default:');
      expect(errorCase, greaterThan(-1));
      expect(transportError, greaterThan(-1));
      expect(errorCase, lessThan(defaultCase));
      expect(transportError, lessThan(defaultCase));
    },
  );
}
