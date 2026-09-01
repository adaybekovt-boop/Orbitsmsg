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
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/native_rollback.dart';
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
        'type': 'room_msg',
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
    expect(hangup?.type, CallSignalType.hangup);
    expect(b.journal.length, greaterThan(0));
    expect(
      b.journal.records.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(kRoomsApplicationE2eImplemented, isFalse);
    kRoomPlaintextSessionAck.reset();
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
    await Future<void>.delayed(const Duration(milliseconds: 30));
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
    final src = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}native-path.bin',
    );
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
    await Future<void>.delayed(const Duration(milliseconds: 80));
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
    a.revokeDevice('phone-2');
    expect(devices.acceptsWriter('phone-2'), isFalse);
    expect(
      devices.transportTargets('ORBIT-BBBBBBBBBBBBBBBB'),
      isNot(contains('ORBIT-B2B2B2B2B2B2B2B2')),
    );
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
}
