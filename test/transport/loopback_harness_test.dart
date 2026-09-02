import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';
import 'package:orbits_flutter/transport/transport_api.dart';

bool _attachCipherExists(String fileId) {
  for (final entity in Directory.systemTemp.listSync()) {
    if (entity is! Directory) continue;
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (!name.startsWith('orbits-attach-')) continue;
    if (File('${entity.path}${Platform.pathSeparator}$fileId.bin')
        .existsSync()) {
      return true;
    }
  }
  return false;
}

DeviceBinding _binding(String deviceId) {
  return DeviceBinding(
    version: kDeviceBindingVersion,
    identityPublicKey: Uint8List.fromList(const [1, 2, 3]),
    deviceId: deviceId,
    transportPublicKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
    hypercorePublicKey: Uint8List.fromList(List<int>.generate(32, (i) => 32 - i)),
    capabilities: const ['peerjs-v4'],
    createdAt: 1,
    expiresAt: 2,
    signatureByIdentityKey: Uint8List.fromList(const [9]),
  );
}

void main() {
  final secret = List<int>.generate(32, (i) => i + 3);

  Future<(LoopbackOrbitsTransport, LoopbackOrbitsTransport)> paired() async {
    final pair = loopbackPair();
    final a = pair.$1;
    final b = pair.$2;
    await a.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await b.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await a.publish(_binding('dev-a'));
    await b.publish(_binding('dev-b'));
    final auth = a.events
        .where((e) => e is TransportAuthenticated)
        .cast<TransportAuthenticated>()
        .first;
    await a.connect(
      PeerDescriptor(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await auth.timeout(const Duration(seconds: 2));
    return (a, b);
  }

  test('echoes text on the message channel', () async {
    final (a, b) = await paired();
    final reply = a.events
        .where((e) => e is TransportFrame)
        .cast<TransportFrame>()
        .firstWhere(
      (e) =>
          e.channel == TransportChannel.message &&
          decodeJsonPayload(e.bytes)['type'] == 'harness-echo-reply',
    );
    await a.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      jsonPayload({'type': 'harness-echo', 'id': '1', 'text': 'ping'}),
    );
    final frame = await reply.timeout(const Duration(seconds: 2));
    expect(decodeJsonPayload(frame.bytes)['text'], 'ping');
    await a.stop();
    await b.stop();
  });

  test('carries an opaque wire-v4 hello without parsing it', () async {
    final (a, b) = await paired();
    final seen = b.events
        .where((e) => e is TransportFrame)
        .cast<TransportFrame>()
        .firstWhere((e) => e.channel == TransportChannel.control);
    final hello = jsonPayload({
      'type': 'wireHello',
      'v': 4,
      'pub': 'AAAA',
      'idPub': 'BBBB',
      'sig': 'CCCC',
      'x3dhIk': 'DDDD',
      'x3dhIkSig': 'EEEE',
      'ek': 'FFFF',
      'spkId': 'spk-1',
    });
    await a.send('ORBIT-BBBBBBBBBBBBBBBB', TransportChannel.control, hello);
    final frame = await seen.timeout(const Duration(seconds: 2));
    expect(decodeJsonPayload(frame.bytes)['v'], 4);
    expect(decodeJsonPayload(frame.bytes)['type'], 'wireHello');
    await a.stop();
    await b.stop();
  });

  test('streams a file from a path and verifies the hash', () async {
    final (a, b) = await paired();
    final received = b.events
        .where((e) => e is TransportFrame)
        .cast<TransportFrame>()
        .firstWhere((e) {
      if (e.channel != TransportChannel.attachment) return false;
      return decodeJsonPayload(e.bytes)['type'] == 'harness-file-received';
    });
    final src = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}harness-src.bin',
    );
    await src.writeAsBytes(List<int>.generate(80 * 1024, (i) => i % 251));
    await a.sendFile(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportFileDescriptor(
        path: src.path,
        sizeBytes: src.lengthSync(),
        fileName: 'harness-src.bin',
      ),
    );
    final frame = await received.timeout(const Duration(seconds: 3));
    final body = decodeJsonPayload(frame.bytes);
    final out = File(body['path'] as String);
    expect(out.existsSync(), isTrue);
    expect(out.lengthSync(), src.lengthSync());
    expect(out.readAsBytesSync(), src.readAsBytesSync());
    await a.stop();
    await b.stop();
  });

  test('sendFile interrupt then resume writes a complete hashed file', () async {
    final (a, b) = await paired();
    final received = b.events
        .where((e) => e is TransportFrame)
        .cast<TransportFrame>()
        .firstWhere((e) {
      if (e.channel != TransportChannel.attachment) return false;
      return decodeJsonPayload(e.bytes)['type'] == 'harness-file-received';
    });
    final src = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}harness-survive.bin',
    );
    await src.writeAsBytes(List<int>.generate(80 * 1024, (i) => i % 251));
    a.debugFileSendBudget = kFileChunkSize;
    await expectLater(
      a.sendFile(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportFileDescriptor(
          path: src.path,
          sizeBytes: src.lengthSync(),
          fileName: 'harness-survive.bin',
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('file-send interrupted'),
        ),
      ),
    );
    a.debugFileSendBudget = null;
    await a.sendFile(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportFileDescriptor(
        path: src.path,
        sizeBytes: src.lengthSync(),
        fileName: 'harness-survive.bin',
        resumeOffset: kFileChunkSize,
      ),
    );
    final frame = await received.timeout(const Duration(seconds: 3));
    final body = decodeJsonPayload(frame.bytes);
    final out = File(body['path'] as String);
    expect(out.existsSync(), isTrue);
    expect(out.readAsBytesSync(), src.readAsBytesSync());
    expect(
      File('lib/transport/loopback_transport.dart').readAsStringSync(),
      isNot(contains('incoming.bytes.addAll')),
    );
    expect(
      File('lib/transport/loopback_transport.dart').readAsStringSync(),
      contains('harness-file-resume'),
    );
    await a.stop();
    await b.stop();
  });

  test('sendFile resumeOffset out of range is rejected', () async {
    final (a, b) = await paired();
    final src = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}harness-resume.bin',
    );
    await src.writeAsBytes(List<int>.filled(1024, 1));
    await expectLater(
      a.sendFile(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportFileDescriptor(
          path: src.path,
          sizeBytes: 1024,
          resumeOffset: 2048,
        ),
      ),
      throwsStateError,
    );
    await a.stop();
    await b.stop();
  });

  test('suspend blocks send and resume restores it', () async {
    final (a, b) = await paired();
    await a.suspend();
    expect(
      () => a.send(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportChannel.message,
        jsonPayload({'type': 'harness-echo', 'id': 'x', 'text': 'no'}),
      ),
      throwsStateError,
    );
    await a.resume();
    final reply = a.events
        .where((e) => e is TransportFrame)
        .cast<TransportFrame>()
        .firstWhere(
      (e) =>
          e.channel == TransportChannel.message &&
          decodeJsonPayload(e.bytes)['type'] == 'harness-echo-reply',
    );
    await a.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      jsonPayload({'type': 'harness-echo', 'id': 'y', 'text': 'yes'}),
    );
    expect(
      decodeJsonPayload(
        (await reply.timeout(const Duration(seconds: 2))).bytes,
      )['text'],
      'yes',
    );
    await a.stop();
    await b.stop();
  });

  test('inbound attach-chunk emits attach-chunk-path for a clean body', () async {
    final (a, b) = await paired();
    final received = b.events
        .where((e) => e is TransportFrame)
        .cast<TransportFrame>()
        .firstWhere((e) {
      if (e.channel != TransportChannel.attachment) return false;
      return decodeJsonPayload(e.bytes)['type'] == 'attach-chunk-path';
    });
    final cipher = utf8.encode('clean-cipher');
    await a.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.attachment,
      jsonPayload({
        'type': 'attach-chunk',
        'fileId': 'chat-clean',
        'offset': 0,
        'b64': base64Encode(cipher),
      }),
    );
    final frame = await received.timeout(const Duration(seconds: 2));
    final body = decodeJsonPayload(frame.bytes);
    expect(body['fileId'], 'chat-clean');
    expect(body['path'], isNot(contains('://')));
    final out = File(body['path'] as String);
    expect(out.existsSync(), isTrue);
    expect(out.readAsBytesSync(), cipher);
    await a.stop();
    await b.stop();
  });

  test('inbound attach-chunk drops nested fileKey and does not write cipher',
      () async {
    final (a, b) = await paired();
    final types = <String>[];
    final pathFileIds = <String>[];
    final barrier = Completer<void>();
    final sub = b.events.listen((e) {
      if (e is! TransportFrame || e.channel != TransportChannel.attachment) {
        return;
      }
      final body = decodeJsonPayload(e.bytes);
      types.add(body['type'] as String? ?? '');
      if (body['type'] != 'attach-chunk-path') return;
      final id = body['fileId'] as String? ?? '';
      pathFileIds.add(id);
      if (id == 'chat-after-nested' && !barrier.isCompleted) {
        barrier.complete();
      }
    });
    await a.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.attachment,
      jsonPayload({
        'type': 'attach-chunk',
        'fileId': 'chat-nested',
        'offset': 0,
        'b64': base64Encode(utf8.encode('nested-cipher')),
        'meta': {'fileKey': 'nope'},
      }),
    );
    // Ingest is serialized on `_attachmentIo`. A later clean chunk's
    // attach-chunk-path means the nested body already ran and was dropped.
    await a.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.attachment,
      jsonPayload({
        'type': 'attach-chunk',
        'fileId': 'chat-after-nested',
        'offset': 0,
        'b64': base64Encode(utf8.encode('after-cipher')),
      }),
    );
    await barrier.future.timeout(const Duration(seconds: 2));
    expect(types, isNot(contains('attach-chunk')));
    expect(pathFileIds, isNot(contains('chat-nested')));
    expect(pathFileIds, contains('chat-after-nested'));
    expect(_attachCipherExists('chat-nested'), isFalse);
    expect(_attachCipherExists('chat-after-nested'), isTrue);
    await sub.cancel();
    await a.stop();
    await b.stop();
  });

  test('path is direct and Noise key is not the identity key', () async {
    final pair = loopbackPair();
    final a = pair.$1;
    final b = pair.$2;
    await a.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await b.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await a.publish(_binding('dev-a'));
    await b.publish(_binding('dev-b'));
    final authFuture = a.events
        .where((e) => e is TransportAuthenticated)
        .cast<TransportAuthenticated>()
        .first;
    await a.connect(
      PeerDescriptor(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    final auth = await authFuture.timeout(const Duration(seconds: 2));
    expect(
      auth.binding.transportPublicKey,
      isNot(equals(auth.binding.identityPublicKey)),
    );
    expect(
      utf8.decode(auth.binding.transportPublicKey),
      isNot(contains('ORBIT-')),
    );
    await a.refreshNetwork();
    await a.stop();
    await b.stop();
  });

  test('connect joins a remote topic that is not the local advertise topic',
      () async {
    final pair = loopbackPair();
    final a = pair.$1;
    final tabletSecret = List<int>.generate(32, (i) => i + 40);
    final tablet = LoopbackOrbitsTransport(hub: a.hub);
    await a.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await tablet.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-A2A2A2A2A2A2A2A2',
        discoverySecret: tabletSecret,
      ),
    );
    await a.publish(_binding('dev-a'));
    await tablet.publish(_binding('dev-a2'));
    await a.connect(
      PeerDescriptor(
        peerId: 'ORBIT-A2A2A2A2A2A2A2A2',
        discoverySecret: tabletSecret,
      ),
    );
    expect(a.lastConnect?.peerId, 'ORBIT-A2A2A2A2A2A2A2A2');
    await a.send(
      'ORBIT-A2A2A2A2A2A2A2A2',
      TransportChannel.message,
      utf8.encode('sync-copy'),
    );
    expect(a.sentPeerIds, contains('ORBIT-A2A2A2A2A2A2A2A2'));
    await a.stop();
    await tablet.stop();
  });

  test('start hydrates Autobase from journal rows already on the carrier',
      () async {
    final t = LoopbackOrbitsTransport();
    await t.appendJournal({
      'kind': 'roomMembershipChanged',
      'writerDeviceId': 'dev-a',
      'seq': 0,
      'fields': {
        'peerId': 'ORBIT-CCCCCCCCCCCCCCCC',
        'action': 'join',
        'displayName': 'C',
      },
    });
    await t.start(
      const TransportLocalConfiguration(peerId: 'ORBIT-AAAAAAAAAAAAAAAA'),
    );
    final snap = await t.listAutobase();
    expect((snap['members'] as Map)['ORBIT-CCCCCCCCCCCCCCCC'], 'C');
    final start = File('lib/transport/loopback_transport.dart')
        .readAsStringSync()
        .split('Future<void> start')[1]
        .split('Future<void> stop')[0];
    expect(start, contains('hydrateFromJournal'));
    await t.stop();
  });

  test('hydrateAutobase and listAutobase rebuild membership from journal',
      () async {
    final pair = loopbackPair();
    await pair.$1.start(
      const TransportLocalConfiguration(peerId: 'ORBIT-AAAAAAAAAAAAAAAA'),
    );
    expect(await pair.$1.listAutobase(), containsPair('members', isEmpty));
    await pair.$1.appendJournal({
      'kind': 'roomMembershipChanged',
      'writerDeviceId': 'dev-a',
      'seq': 0,
      'fields': {
        'peerId': 'ORBIT-CCCCCCCCCCCCCCCC',
        'action': 'join',
        'displayName': 'C',
        'roomId': 'room-1',
      },
    });
    final snap = await pair.$1.listAutobase();
    expect((snap['members'] as Map)['ORBIT-CCCCCCCCCCCCCCCC'], 'C');
    await pair.$1.hydrateAutobase([
      {
        'kind': 'roomMembershipChanged',
        'writerDeviceId': 'dev-a',
        'seq': 1,
        'fields': {
          'peerId': 'ORBIT-DDDDDDDDDDDDDDDD',
          'action': 'join',
          'displayName': 'D',
        },
      },
    ]);
    final again = await pair.$1.listAutobase();
    expect((again['members'] as Map)['ORBIT-DDDDDDDDDDDDDDDD'], 'D');
    expect((again['members'] as Map)['ORBIT-CCCCCCCCCCCCCCCC'], 'C');
    await pair.$1.stop();
  });

  test('appendJournal refuses URL-shaped identifier values', () async {
    final pair = loopbackPair();
    await pair.$1.start(
      const TransportLocalConfiguration(peerId: 'ORBIT-AAAAAAAAAAAAAAAA'),
    );
    await expectLater(
      pair.$1.appendJournal({
        'kind': 'deviceRevoked',
        'writerDeviceId': 'dev-a',
        'fields': {'deviceId': 'https://evil'},
      }),
      throwsArgumentError,
    );
    expect(await pair.$1.listJournal(), isEmpty);
    await pair.$1.appendJournal({
      'kind': 'deviceRevoked',
      'writerDeviceId': 'dev-a',
      'fields': {'deviceId': 'phone'},
    });
    expect(await pair.$1.listJournal(), hasLength(1));
    await pair.$1.stop();
  });
}
