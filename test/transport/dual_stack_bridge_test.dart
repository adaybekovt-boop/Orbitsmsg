import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/calls/hyperswarm_signaling.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/storage_peer_client.dart';
import 'package:orbits_flutter/mailbox/storage_peer_http.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';
import 'package:orbits_flutter/peer/room_disclaimer.dart';
import 'package:orbits_flutter/peer/room_plaintext_gate.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/rooms/autobase_log.dart';
import 'package:orbits_flutter/core/path_byte_stream.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/native_rollback.dart';
import 'package:orbits_flutter/transport/relay_directory.dart';
import 'package:orbits_flutter/transport/transport_api.dart';

DeviceBinding _bind(String id) => DeviceBinding(
      version: kDeviceBindingVersion,
      identityPublicKey: Uint8List.fromList(const [1]),
      deviceId: id,
      transportPublicKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
      hypercorePublicKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 2)),
      capabilities: const ['hyperswarm-v1'],
      createdAt: 1,
      expiresAt: 2,
      signatureByIdentityKey: Uint8List.fromList(const [3]),
    );

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  final secret = List<int>.generate(32, (i) => 9);

  Future<(DualStackBridge, DualStackBridge, List<Object?>)> linked({
    Set<String> blocked = const {},
    BlindMailboxStore? mailbox,
  }) async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final packets = <Object?>[];
    DualStackBridge make(LoopbackOrbitsTransport t, String self, String device) {
      return DualStackBridge(
        transport: t,
        journal: MemoryJournal(device),
        selfPeerId: () => self,
        selfDeviceId: device,
        secrets: secrets,
        isBlocked: blocked.contains,
        mailbox: mailbox,
        mailboxToken: mailbox == null ? null : 'cap-1',
        mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
        onPacket: (peer, data) async {
          packets.add(data);
        },
      )..attach();
    }

    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(_bind('a'));
    await pair.$2.publish(_bind('b'));
    final a = make(pair.$1, 'ORBIT-AAAAAAAAAAAAAAAA', 'dev-a');
    final b = make(pair.$2, 'ORBIT-BBBBBBBBBBBBBBBB', 'dev-b');
    await pair.$1.connect(
      const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return (a, b, packets);
  }

  test('flag off never selects native even with a secret', () async {
    final (a, _, _) = await linked();
    resetFlagsForTests();
    expect(a.canUseNative('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);
  });

  test('blocked peer is dropped before packet delivery', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final seen = <Object?>[];
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(_bind('a'));
    await pair.$2.publish(_bind('b'));
    DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      isBlocked: (id) => id == 'ORBIT-AAAAAAAAAAAAAAAA',
      onPacket: (peer, data) async => seen.add(data),
    ).attach();
    await pair.$1.connect(
      const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
    );
    await pair.$1.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      utf8.encode('v2:hdr:iv:ct'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen, isEmpty);
  });

  test('two natives exchange current wire + rooms + call signals without Hypercore',
      () async {
    final (a, b, packets) = await linked();
    expect(a.canUseNative('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    kRoomPlaintextSessionAck.setAcknowledged(true);
    final rooms = <Map<String, Object?>>[];
    CallSignal? hangup;
    b.onPacket = (peer, data) async {
      if (data is Map) rooms.add(Map<String, Object?>.from(data));
      packets.add(data);
    };
    b.onCallSignal = (signal, from) {
      hangup = signal;
    };

    await a.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
      'type': 'wireHello',
      'v': 4,
    });
    await a.transport.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      utf8.encode('v2:aaa:bbb:ccc'),
    );
    expect(
      a.sendRoomPacket('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'room_join',
        'guestPeerId': 'ORBIT-AAAAAAAAAAAAAAAA',
        'guestName': 'A',
      }),
      isTrue,
    );
    expect(
      a.sendRoomPacket('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'room_msg',
        'id': 'm-host',
        'text': 'host-plaintext',
      }),
      isTrue,
    );
    final caller = NativeCallSession(
      send: (s) => a.sendCallSignal('ORBIT-BBBBBBBBBBBBBBBB', s),
    );
    await caller.startOutgoing(callId: 'c1', sdp: 'v=0-offer');
    await caller.addIce({'candidate': '1.2.3.4'});
    await caller.accept(sdp: 'v=0-answer');
    await a.sendCallSignal(
      'ORBIT-BBBBBBBBBBBBBBBB',
      const CallSignal(type: CallSignalType.hangup, callId: 'c1'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(
      packets.whereType<String>().any((p) => p.startsWith('v2:')),
      isTrue,
    );
    expect(
      rooms.any((r) => r['type'] == 'wireHello' && r['v'] == 4),
      isTrue,
    );
    expect(
      rooms.any((r) => r['type'] == 'room_msg' && r['text'] == 'host-plaintext'),
      isTrue,
    );
    expect(a.rooms.state.members['ORBIT-AAAAAAAAAAAAAAAA'], 'A');
    expect(b.rooms.state.members['ORBIT-AAAAAAAAAAAAAAAA'], 'A');
    expect(
      b.rooms.state.messages.any((m) => m['text'] == 'host-plaintext'),
      isTrue,
    );
    expect(
      a.journal.records.every((r) => !r.fields.containsKey('text')),
      isTrue,
    );
    expect(hangup?.type, CallSignalType.hangup);
    expect(b.journal.length, greaterThan(0));
    expect(
      b.journal.records.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(kRoomsApplicationE2eImplemented, isFalse);
    kRoomPlaintextSessionAck.reset();
  });

  test('DualStackBridge persists ciphertext onto the carrier journal', () async {
    final (a, b, _) = await linked();
    a.revokeDevice('gone-device');
    await a.verifyLiveMatchesReplay();
    await a.transport.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      utf8.encode('v2:aaa:bbb:ccc'),
    );
    List<Map<String, Object?>> envelopes = const [];
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      await b.verifyLiveMatchesReplay();
      envelopes = await b.transport.listJournal();
      if (envelopes.any((row) {
        final fields = row['fields'];
        return fields is Map && fields['encryptedEnvelope'] != null;
      })) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final revoked = await a.transport.listJournal();
    expect(
      revoked.any((row) => row['kind'] == 'deviceRevoked'),
      isTrue,
    );
    expect(jsonEncode(revoked), isNot(contains('rootKey')));
    expect(jsonEncode(revoked), isNot(contains('plaintext')));
    expect(
      envelopes.any((row) {
        final fields = row['fields'];
        return fields is Map && fields['encryptedEnvelope'] != null;
      }),
      isTrue,
    );
    expect(jsonEncode(envelopes), isNot(contains('plaintext')));
    final restored = MemoryJournal('dev-b-restore');
    expect(ingestWorkletRows(restored, envelopes), greaterThan(0));
    final liveEnc = b.journal.records
        .map((r) => r.fields['encryptedEnvelope'])
        .whereType<List<int>>()
        .first;
    final restoredEnc = restored.records
        .map((r) => r.fields['encryptedEnvelope'])
        .whereType<List<int>>()
        .first;
    expect(restoredEnc, liveEnc);
    expect(
      restored.records.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(
      restored.records.every((r) => !r.fields.containsKey('rootKey')),
      isTrue,
    );
  });

  test('attachment chunks journal ciphertext and never the fileKey', () async {
    final (a, b, _) = await linked();
    final key = List<int>.generate(32, (i) => i + 3);
    final plain = List<int>.generate(80, (i) => i);
    await a.sendAttachmentChunks('ORBIT-BBBBBBBBBBBBBBBB', plain, key);
    List<Map<String, Object?>> rows = const [];
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      rows = await a.transport.listJournal();
      if (rows.any((row) => row['kind'] == 'attachmentPublished')) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      rows.any((row) => row['kind'] == 'attachmentPublished'),
      isTrue,
    );
    expect(jsonEncode(rows), isNot(contains('fileKey')));
    expect(jsonEncode(rows), isNot(contains('plaintext')));
    expect(jsonEncode(rows), isNot(contains('attachmentBytes')));
    expect(
      a.journal.records.any((r) {
        final enc = r.fields['encryptedEnvelope'];
        return r.kind == ReplicationEventKind.attachmentPublished &&
            enc is List<int> &&
            enc.isNotEmpty;
      }),
      isTrue,
    );

    final dir = Directory.systemTemp.createTempSync('orbits-att-stream-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final file = File('${dir.path}${Platform.pathSeparator}blob.bin')
      ..writeAsBytesSync(plain);
    await a.sendAttachmentStream(
      'ORBIT-BBBBBBBBBBBBBBBB',
      file.openRead(),
      key,
    );
    expect(
      a.journal.records
          .where((r) => r.kind == ReplicationEventKind.attachmentPublished)
          .length,
      greaterThanOrEqualTo(2),
    );
    expect(
      a.journal.records.every((r) => !r.fields.containsKey('fileKey')),
      isTrue,
    );
  });

  test('attach-chunk is not Drop and decrypts with the local fileKey', () async {
    final (a, b, _) = await linked();
    final drop = <Object>[];
    b.onDrop = (peer, packet) => drop.add(packet);
    final key = List<int>.generate(32, (i) => i + 4);
    final plain = List<int>.generate(90, (i) => i + 1);
    await a.sendAttachmentChunks(
      'ORBIT-BBBBBBBBBBBBBBBB',
      plain,
      key,
      fileId: 'chat-file-1',
    );
    Uint8List? got;
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      got = await b.decryptInboundAttachment(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'chat-file-1',
        key,
      );
      if (got != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(got, Uint8List.fromList(plain));
    expect(drop, isEmpty);
    expect(jsonEncode(a.journal.records.map((r) => r.fields).toList()),
        isNot(contains('fileKey')));
    expect(jsonEncode(a.journal.records.map((r) => r.fields).toList()),
        isNot(contains('fileKeyB64')));
  });

  test('attach-chunk via ciphertext path sendFile is not Dart frameB64', () async {
    final (a, b, _) = await linked();
    final drop = <Object>[];
    b.onDrop = (peer, packet) => drop.add(packet);
    final key = List<int>.generate(32, (i) => i + 6);
    final plain = List<int>.generate(90, (i) => i + 2);
    final dir = Directory.systemTemp.createTempSync('orbits-att-cipher-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final src = File('${dir.path}${Platform.pathSeparator}plain.bin')
      ..writeAsBytesSync(plain);
    final write = await xorPlaintextPathToCipherFile(src.path, key);
    expect(write, isNotNull);
    addTearDown(write!.dispose);
    expect(
      await a.sendAttachmentCipherPath(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportFileDescriptor(
          path: write.path,
          sizeBytes: write.sizeBytes,
          protocol: 'attach-chunk',
          fileId: 'chat-file-path',
        ),
        firstCipher: write.firstCipher,
        chunkCount: write.chunkCount,
      ),
      isTrue,
    );
    Uint8List? got;
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      got = await b.decryptInboundAttachment(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'chat-file-path',
        key,
      );
      if (got != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(got, Uint8List.fromList(plain));
    expect(drop, isEmpty);
    expect(
      a.journal.records.any((r) => r.kind == ReplicationEventKind.attachmentPublished),
      isTrue,
    );
    expect(jsonEncode(a.journal.records.map((r) => r.fields).toList()),
        isNot(contains('fileKey')));
    expect(jsonEncode(a.journal.records.map((r) => r.fields).toList()),
        isNot(contains('fileKeyB64')));
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      isNot(contains("import 'dart:io'")),
    );
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('xorPlaintextPathToCipherFile'),
    );
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('sendAttachmentCipherPath'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains("'protocol': file.protocol"),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      isNot(contains("'fileKey'")),
    );
    expect(
      File('lib/transport/loopback_transport.dart').readAsStringSync(),
      contains('attach-chunk-path'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('xorCipherPathToPlaintext'),
    );
  });

  test('recipient reads mailbox after the sender is gone', () async {
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 4096,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final seen = <Object?>[];
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(_bind('a'));
    await pair.$2.publish(_bind('b'));
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      onPacket: (peer, data) async {},
    )..attach();
    final b = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      onPacket: (peer, data) async => seen.add(data),
    )..attach();
    expect(
      await a.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'wireHello',
        'v': 4,
      }),
      isTrue,
    );
    await pair.$1.stop();
    final n = await b.drainMailbox(fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA');
    expect(n, greaterThan(0));
    expect(
      seen.whereType<Map>().any((m) => m['type'] == 'wireHello'),
      isTrue,
    );
    expect(store.pendingCount('ORBIT-AAAAAAAAAAAAAAAA'), 0);
    expect(await b.verifyLiveMatchesReplay(), isTrue);
    expect(b.hypercoreMatchesJournal(), isTrue);
  });

  test('drop chunks and hypercore replication ride native channels', () async {
    final (a, b, _) = await linked();
    final dropped = <Object>[];
    b.onDrop = (peer, packet) => dropped.add(packet);
    await a.sendDrop('ORBIT-BBBBBBBBBBBBBBBB', {
      'type': 'file-start',
      'fileId': 'f1',
      'name': 'a.bin',
      'size': 3,
    });
    await a.transport.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      utf8.encode('v2:aaa:bbb:ccc'),
    );
    final dropDeadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(dropDeadline) &&
        !dropped.whereType<Map>().any((m) => m['type'] == 'file-start')) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      dropped.whereType<Map>().any((m) => m['type'] == 'file-start'),
      isTrue,
    );
    expect(b.hypercore.blocks, isNotEmpty);
    expect(
      b.hypercore.blocks.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(b.hypercoreMatchesJournal(), isTrue);
  });

  test('native sendFileFromPath streams from a path, not bytes', () async {
    final (a, b, _) = await linked();
    final dropped = <Object>[];
    b.onDrop = (peer, packet) => dropped.add(packet);
    final dir = await Directory.systemTemp.createTemp('orbits-path-');
    addTearDown(() => dir.delete(recursive: true));
    final src = File('${dir.path}${Platform.pathSeparator}native-path.bin');
    await src.writeAsBytes(List<int>.generate(80 * 1024, (i) => i % 251));
    expect(
      await a.sendFileFromPath(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportFileDescriptor(
          path: src.path,
          sizeBytes: src.lengthSync(),
          fileName: 'native-path.bin',
        ),
      ),
      isTrue,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline) &&
        !dropped.whereType<Map>().any((m) => m['type'] == 'harness-file-received')) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    expect(
      dropped.whereType<Map>().any((m) => m['type'] == 'harness-file-start'),
      isTrue,
    );
    expect(
      dropped.whereType<Map>().any((m) => m['type'] == 'harness-file-received'),
      isTrue,
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('transport.sendFile'),
    );
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('sendFileFromPath'),
    );
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('sendAutobaseEvent'),
    );
  });

  test('native path attachment survives loss and resumes from offset', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    DualStackBridge make(LoopbackOrbitsTransport t, String self, String device) {
      return DualStackBridge(
        transport: t,
        journal: MemoryJournal(device),
        selfPeerId: () => self,
        selfDeviceId: device,
        secrets: secrets,
        isBlocked: (_) => false,
        onPacket: (_, __) async {},
      )..attach();
    }

    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(_bind('a'));
    await pair.$2.publish(_bind('b'));
    final a = make(pair.$1, 'ORBIT-AAAAAAAAAAAAAAAA', 'dev-a');
    final b = make(pair.$2, 'ORBIT-BBBBBBBBBBBBBBBB', 'dev-b');
    await pair.$1.connect(
      const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final dropped = <Object>[];
    b.onDrop = (peer, packet) => dropped.add(packet);
    final dir = await Directory.systemTemp.createTemp('orbits-survive-');
    addTearDown(() => dir.delete(recursive: true));
    final src = File('${dir.path}${Platform.pathSeparator}survive.bin');
    await src.writeAsBytes(List<int>.generate(80 * 1024, (i) => i % 251));
    pair.$1.debugFileSendBudget = 64 * 1024;
    await expectLater(
      a.sendFileFromPath(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportFileDescriptor(
          path: src.path,
          sizeBytes: src.lengthSync(),
          fileName: 'survive.bin',
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
    pair.$1.debugFileSendBudget = null;
    expect(
      await a.sendFileFromPath(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportFileDescriptor(
          path: src.path,
          sizeBytes: src.lengthSync(),
          fileName: 'survive.bin',
          resumeOffset: 64 * 1024,
        ),
      ),
      isTrue,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline) &&
        !dropped.whereType<Map>().any((m) => m['type'] == 'harness-file-received')) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    final received = dropped.whereType<Map>().firstWhere(
          (m) => m['type'] == 'harness-file-received',
        );
    expect(File(received['path'] as String).readAsBytesSync(), src.readAsBytesSync());
    await a.detach();
    await b.detach();
    await pair.$1.stop();
    await pair.$2.stop();
  });

  test('device revoke is journaled and drops that writer from fan-out', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final devices = DeviceRegistry();
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('dev-a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'dev-a',
      secrets: secrets,
      devices: devices,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    a.authorizeDevice(
      AuthorizedDevice(
        deviceId: 'phone-2',
        transportPublicKey: List<int>.filled(32, 1),
        hypercorePublicKey: List<int>.filled(32, 2),
        name: 'phone-2',
        kind: 'phone',
        createdAt: 1,
        status: DeviceStatus.active,
        ownerPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        transportPeerId: 'ORBIT-B2B2B2B2B2B2B2B2',
      ),
    );
    expect(
      devices.transportTargets('ORBIT-BBBBBBBBBBBBBBBB'),
      contains('ORBIT-B2B2B2B2B2B2B2B2'),
    );
    final dropped = <String>[];
    a.onRatchetDropped = dropped.add;
    a.revokeDevice('phone-2');
    expect(devices.acceptsWriter('phone-2'), isFalse);
    expect(
      devices.transportTargets('ORBIT-BBBBBBBBBBBBBBBB'),
      isNot(contains('ORBIT-B2B2B2B2B2B2B2B2')),
    );
    expect(dropped, ['ORBIT-B2B2B2B2B2B2B2B2']);
    expect(dropped, isNot(contains('ORBIT-BBBBBBBBBBBBBBBB')));
    expect(
      a.journal.records.any((r) => r.kind == ReplicationEventKind.deviceRevoked),
      isTrue,
    );
    expect(
      a.journal.records.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    await a.detach();
  });

  test('recipient reads mailbox over HTTP after the sender is gone', () async {
    final http = StoragePeerHttp(BlindMailboxStore());
    await http.start();
    addTearDown(http.stop);
    final client = httpStoragePeerClient(http.origin);
    await client.grant(
      MailboxCapability(
        token: 'cap-http',
        quotaBytes: 4096,
        retentionMs: 60 * 1000,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
      ),
    );
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final seen = <Object?>[];
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(_bind('a'));
    await pair.$2.publish(_bind('b'));
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      isBlocked: (_) => false,
      storagePeer: client,
      mailboxToken: 'cap-http',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      onPacket: (peer, data) async {},
    )..attach();
    final b = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      isBlocked: (_) => false,
      storagePeer: client,
      mailboxToken: 'cap-http',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      onPacket: (peer, data) async => seen.add(data),
    )..attach();
    expect(a.hasMailbox, isTrue);
    expect(
      await a.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'wireHello',
        'v': 4,
      }),
      isTrue,
    );
    await pair.$1.stop();
    final n = await b.drainMailbox(fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA');
    expect(n, greaterThan(0));
    expect(
      seen.whereType<Map>().any((m) => m['type'] == 'wireHello'),
      isTrue,
    );
    expect(await b.drainMailbox(fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA'), 0);
    await a.detach();
    await b.detach();
  });

  test('HTTP storage peer rejects plaintext and anonymous writes', () async {
    final http = StoragePeerHttp(BlindMailboxStore());
    await http.start();
    addTearDown(http.stop);
    expect(
      storagePeerBodyIsSafe({
        'token': 'cap',
        'writerKey': 'w',
        'b64': 'YQ==',
        'plaintext': 'nope',
      }),
      isFalse,
    );
    expect(
      storagePeerBodyIsSafe({
        'token': '',
        'writerKey': 'w',
        'b64': 'YQ==',
      }),
      isFalse,
    );
    expect(storagePeerGrantIsSafe({'token': ''}), isFalse);
    expect(
      storagePeerGrantIsSafe({'token': 'cap', 'plaintext': 'x'}),
      isFalse,
    );

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<int> post(String path, Map<String, Object?> body) async {
      final req = await client.postUrl(Uri.parse('${http.origin}$path'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    }

    expect(
      await post('/v1/grant', {'token': '', 'quotaBytes': 10}),
      400,
    );
    expect(
      await post('/v1/grant', {'token': 'cap', 'plaintext': 'hi'}),
      400,
    );
    expect(
      await post('/v1/blocks', {
        'token': 'cap',
        'writerKey': 'w',
        'seq': 0,
        'b64': 'YQ==',
        'plaintext': 'secret',
      }),
      400,
    );
    expect(
      await post('/v1/blocks', {
        'token': '',
        'writerKey': 'w',
        'seq': 0,
        'b64': 'YQ==',
      }),
      400,
    );
  });

  test('blocked mailbox drain tombstones without decrypt or journal persist',
      () async {
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 4096,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final seen = <Object?>[];
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      onPacket: (_, __) async {},
    )..attach();
    final b = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      isBlocked: (id) => id == 'ORBIT-AAAAAAAAAAAAAAAA',
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      onPacket: (peer, data) async => seen.add(data),
    )..attach();
    expect(
      await a.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'wireHello',
        'v': 4,
      }),
      isTrue,
    );
    final n = await b.drainMailbox(fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA');
    expect(n, 0);
    expect(seen, isEmpty);
    expect(b.journal.length, 0);
    expect(store.pendingCount('ORBIT-AAAAAAAAAAAAAAAA'), 0);
    await a.detach();
    await b.detach();
  });

  test('mailbox quota and backlog force PeerJS rollback', () async {
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 4,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    setHyperswarmRollout(HyperswarmRollout.internal);
    clearNativeRollbackLogForTests();
    final pair = loopbackPair();
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'writer',
      onPacket: (_, __) async {},
    )..attach();
    expect(await a.depositMailbox(const [1, 2, 3, 4]), isTrue);
    await a.checkMailboxBacklog(maxBytes: 4, maxCount: 100);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(
      nativeRollbackLog.last.reason,
      NativeRollbackReason.relayMailboxBacklog,
    );
    setHyperswarmRollout(HyperswarmRollout.internal);
    expect(await a.depositMailbox(const [5, 6, 7, 8, 9]), isFalse);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(
      nativeRollbackLog.last.reason,
      NativeRollbackReason.relayMailboxBacklog,
    );
    await a.detach();
  });

  test('lost messages and journal mismatch rollback to PeerJS', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    clearNativeRollbackLogForTests();
    final pair = loopbackPair();
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    expect(a.noteMessagesLost('ack timeout'), isTrue);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(
      nativeRollbackLog.single.reason,
      NativeRollbackReason.messagesLost,
    );
    setHyperswarmRollout(HyperswarmRollout.internal);
    a.hypercore.append(
      const JournalRecord(
        seq: 99,
        writerDeviceId: 'other',
        kind: ReplicationEventKind.messageEnvelopeCreated,
        fields: {
          'eventId': 'orphan',
          'encryptedEnvelope': <int>[1],
        },
      ),
    );
    expect(await a.verifyLiveMatchesReplay(), isFalse);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(
      nativeRollbackLog.last.reason,
      NativeRollbackReason.driftJournalDiverge,
    );
    await a.detach();
  });

  test('Autobase writers converge on the native carrier without Hypercore plaintext',
      () async {
    final (a, b, _) = await linked();
    expect(
      await a.sendAutobaseEvent(
        'ORBIT-BBBBBBBBBBBBBBBB',
        const RoomEvent(
          writerId: 'a',
          seq: 0,
          kind: 'membership',
          payload: {
            'peerId': 'ORBIT-AAAAAAAAAAAAAAAA',
            'action': 'join',
            'displayName': 'A',
          },
        ),
      ),
      isTrue,
    );
    expect(
      await b.sendAutobaseEvent(
        'ORBIT-AAAAAAAAAAAAAAAA',
        const RoomEvent(
          writerId: 'b',
          seq: 0,
          kind: 'membership',
          payload: {
            'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
            'action': 'join',
            'displayName': 'B',
          },
        ),
      ),
      isTrue,
    );
    expect(
      await a.sendAutobaseEvent(
        'ORBIT-BBBBBBBBBBBBBBBB',
        const RoomEvent(
          writerId: 'a',
          seq: 1,
          kind: 'channel',
          payload: {'id': 'c1', 'name': 'general'},
        ),
      ),
      isTrue,
    );
    expect(
      await b.sendAutobaseEvent(
        'ORBIT-AAAAAAAAAAAAAAAA',
        const RoomEvent(
          writerId: 'b',
          seq: 1,
          kind: 'message',
          payload: {'id': 'm1', 'text': 'host-plaintext'},
        ),
      ),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(a.rooms.state.members, b.rooms.state.members);
    expect(a.rooms.state.channels, b.rooms.state.channels);
    expect(a.rooms.state.messages, b.rooms.state.messages);
    expect(a.rooms.state.members['ORBIT-AAAAAAAAAAAAAAAA'], 'A');
    expect(b.rooms.state.channels['c1'], 'general');
    expect(
      a.journal.records.any(
        (r) => r.kind == ReplicationEventKind.roomMembershipChanged,
      ),
      isTrue,
    );
    expect(
      a.journal.records.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(
      a.journal.records.every((r) => !r.fields.containsKey('text')),
      isTrue,
    );
    expect(kRoomsApplicationE2eImplemented, isFalse);
    await a.detach();
    await b.detach();
  });

  test('room_msg is blocked without the plaintext ack', () {
    kRoomPlaintextSessionAck.reset();
    expect(
      sendGuardedRoomPacket(
        {'type': 'room_msg', 'text': 'x'},
        connected: true,
        send: (_) {},
      ),
      isFalse,
    );
  });

  test('dial forwards recipient Noise public key, not identity', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(_bind('a'));
    await pair.$2.publish(_bind('b'));
    final noise = List<int>.generate(32, (i) => 11);
    final devices = DeviceRegistry()
      ..authorize(
        AuthorizedDevice(
          deviceId: 'bob-phone',
          transportPublicKey: noise,
          hypercorePublicKey: List<int>.generate(32, (i) => 12),
          name: 'Bob',
          kind: 'phone',
          createdAt: 1,
          status: DeviceStatus.active,
          ownerPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
          transportPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        ),
      );
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      devices: devices,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    await a.dial('ORBIT-BBBBBBBBBBBBBBBB');
    expect(pair.$1.lastConnect?.peerId, 'ORBIT-BBBBBBBBBBBBBBBB');
    expect(pair.$1.lastConnect?.noisePublicKey, noise);
    expect(pair.$1.lastConnect?.discoverySecret, secret);
    await a.detach();
  });

  test('relay blow-up and carrier error roll back to PeerJS', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    clearNativeRollbackLogForTests();
    final pair = loopbackPair();
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    final empty = RelayDirectory(
      issuedAt: 1,
      expiresAt: 2,
      peers: const [],
      signature: Uint8List(0),
      identityPublicKey: Uint8List(0),
    );
    expect(a.checkRelayDirectory(empty), isFalse);
    expect(hyperswarmRollout(), HyperswarmRollout.internal);

    final blown = RelayDirectory(
      issuedAt: 1,
      expiresAt: 2,
      peers: const [
        DirectoryPeer(
          id: 'r1',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.1',
          port: 1,
          region: 'eu',
          unsound: true,
        ),
        DirectoryPeer(
          id: 'r2',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.2',
          port: 1,
          region: 'eu',
          unsound: true,
        ),
      ],
      signature: Uint8List(0),
      identityPublicKey: Uint8List(0),
    );
    expect(a.checkRelayDirectory(blown), isTrue);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(nativeRollbackLog.last.reason, NativeRollbackReason.relayBlowUp);

    setHyperswarmRollout(HyperswarmRollout.internal);
    pair.$1.emitEvent(const TransportError('relay-blow-up', 'rtt exploded'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(nativeRollbackLog.last.reason, NativeRollbackReason.relayBlowUp);
    expect(nativeRollbackLog.last.detail, 'rtt exploded');
    await a.detach();
  });
}
