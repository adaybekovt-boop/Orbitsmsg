import 'dart:convert';
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
    expect(hydrated['hydrated'], 0);
    expect(hydrated['members'], isA<Map>());

    await pair.client.request('journal.append', {
      'kind': 'roomMembershipChanged',
      'writerDeviceId': 'dev-a',
      'seq': 0,
      'fields': {
        'peerId': 'ORBIT-CCCCCCCCCCCCCCCC',
        'action': 'join',
        'displayName': 'C',
      },
    });
    final membership = await pair.client.request('autobase.hydrate', {
      'rows': pair.worklet.journal,
    });
    expect(membership['hydrated'], greaterThanOrEqualTo(1));
    expect(
      (membership['members'] as Map)['ORBIT-CCCCCCCCCCCCCCCC'],
      'C',
    );

    final state = await pair.client.request('autobase.state');
    expect(state, isA<Map<String, Object?>>());
    expect((state['members'] as Map)['ORBIT-CCCCCCCCCCCCCCCC'], 'C');
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

  test('in-process pair routes connect/send and refuses unsafe sendFile',
      () async {
    final hub = InProcessWorkletHub();
    final a = openInProcessIpc(hub: hub);
    final b = openInProcessIpc(hub: hub);
    final frames = <Map<String, Object?>>[];
    final sub = b.client.events.listen(frames.add);

    await a.client.request('start', {'peerId': 'ORBIT-AAAAAAAAAAAAAAAA'});
    await b.client.request('start', {'peerId': 'ORBIT-BBBBBBBBBBBBBBBB'});
    await a.client.request('publish', {
      'binding': {'deviceId': 'dev-a'},
    });
    await b.client.request('publish', {
      'binding': {'deviceId': 'dev-b'},
    });
    await a.client.request('connect', {'peerId': 'ORBIT-BBBBBBBBBBBBBBBB'});
    expect(a.worklet.connectedPeers, contains('ORBIT-BBBBBBBBBBBBBBBB'));
    expect(b.worklet.connectedPeers, contains('ORBIT-AAAAAAAAAAAAAAAA'));

    await a.client.request('send', {
      'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
      'channel': 'message',
      'frameB64': base64Encode(utf8.encode('{"type":"ping"}')),
    });
    await Future<void>.delayed(Duration.zero);
    expect(a.worklet.sentFrames, isNotEmpty);
    expect(
      frames.any((e) => e['name'] == 'frame'),
      isTrue,
    );

    await expectLater(
      a.client.request('sendFile', {
        'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
        'file': {'path': 'https://evil.example/x'},
      }),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      a.client.request('sendFile', {
        'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
        'file': {
          'path': '/tmp/safe.bin',
          'fileKey': 'nope',
        },
      }),
      throwsA(isA<StateError>()),
    );
    await a.client.request('sendFile', {
      'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
      'file': {
        'path': '/tmp/safe.bin',
        'fileName': 'safe.bin',
        'protocol': 'attach-chunk',
        'fileId': 'att-1',
      },
    });
    expect(a.worklet.sentFiles, hasLength(1));

    await sub.cancel();
    await a.client.close();
    await b.client.close();
  });
}
