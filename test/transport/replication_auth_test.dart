import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/core/identity_key.dart';
import 'package:orbits_flutter/core/peer_pins.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/peer/room_disclaimer.dart';
import 'package:orbits_flutter/replication/file_journal.dart';
import 'package:orbits_flutter/replication/hypercore_store.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/rooms/autobase_log.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';
import 'package:orbits_flutter/transport/replication_auth.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';
import 'package:orbits_flutter/transport/signed_capabilities.dart';
import 'package:orbits_flutter/transport/transport_api.dart';

import '../helpers/pointycastle_ecdh.dart';

late EcKeyPairData _idA;
late EcKeyPairData _idB;
late Uint8List _spkiA;
late Uint8List _spkiB;

const _peerA = 'ORBIT-AAAAAAAAAAAAAAAA';
const _peerB = 'ORBIT-BBBBBBBBBBBBBBBB';
const _peerC = 'ORBIT-CCCCCCCCCCCCCCCC';

Future<DeviceBinding> _bind(
  String id, {
  required Uint8List spki,
  required EcKeyPairData pair,
}) {
  return issueDeviceBinding(
    identityPublicKey: spki,
    deviceId: id,
    transportPublicKey: Uint8List.fromList(
      List<int>.generate(32, (i) => i + 1),
    ),
    hypercorePublicKey: Uint8List.fromList(
      List<int>.generate(32, (i) => i + 2),
    ),
    capabilities: const ['hyperswarm-v1', 'peerjs-v4'],
    createdAt: 1,
    expiresAt: 10,
    sign: (payload) async => signP256Ecdsa(pair, payload),
  );
}

Future<PinCheck> _allowTofu(String _, List<int> __) async =>
    const PinCheck(status: PinStatus.newPin, fingerprint: 'test');

Map<String, Object?> _replFrame({
  required String kind,
  required String writerDeviceId,
  required Map<String, Object?> fields,
  int seq = 99,
}) {
  return <String, Object?>{
    'type': 'repl-event',
    'info': kReplicationEventInfo,
    'kind': kind,
    'seq': seq,
    'writerDeviceId': writerDeviceId,
    'fields': fields,
  };
}

Future<void> _pump([int ms = 50]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  setUpAll(() async {
    _idA = await generateP256EcdsaKey();
    _idB = await generateP256EcdsaKey();
    _spkiA = buildP256Spki(x: _idA.x, y: _idA.y);
    _spkiB = buildP256Spki(x: _idB.x, y: _idB.y);
  });

  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  test('conversationScopedToPeer accepts only the 1:1 pair', () {
    expect(
      conversationScopedToPeer(
        conversationId: _peerB,
        peerId: _peerB,
        selfPeerId: _peerA,
      ),
      isTrue,
    );
    expect(
      conversationScopedToPeer(
        conversationId: _peerA,
        peerId: _peerB,
        selfPeerId: _peerA,
      ),
      isTrue,
    );
    expect(
      conversationScopedToPeer(
        conversationId: _peerC,
        peerId: _peerB,
        selfPeerId: _peerA,
      ),
      isFalse,
    );
  });

  test('canonicalReplicationRecordBytes ignores signature and is stable', () {
    final a = canonicalReplicationRecordBytes(
      kind: ReplicationEventKind.contactBlocked,
      writerDeviceId: 'dev-a',
      fields: {
        'peerId': _peerC,
        'blocked': true,
        'signature': 'nope',
        'createdAt': 1,
      },
    );
    final b = canonicalReplicationRecordBytes(
      kind: ReplicationEventKind.contactBlocked,
      writerDeviceId: 'dev-a',
      fields: {'createdAt': 1, 'blocked': true, 'peerId': _peerC},
    );
    expect(a, b);
  });

  test(
    'roomEventFromNativePacket drops guest abWriter spoof when host is known',
    () {
      expect(
        roomEventFromNativePacket(
          {
            'type': 'room_join',
            'roomId': 'room-1',
            'abWriter': 'dev-a',
            'abSeq': 3,
            'guestPeerId': _peerC,
            'guestName': 'C',
          },
          fallbackWriter: _peerB,
          authenticatedPeer: _peerB,
          authenticatedDeviceId: 'dev-b',
          roomHostFor: (id) => id == 'room-1' ? _peerA : null,
        ),
        isNull,
      );
      expect(
        roomEventFromNativePacket({
          'type': 'room_join',
          'roomId': 'room-1',
          'abWriter': 'dev-a',
          'abSeq': 3,
          'guestPeerId': _peerC,
          'guestName': 'C',
        }, fallbackWriter: 'x')?.payload['peerId'],
        _peerC,
      );
    },
  );

  test('cross-peer replication forgery is dropped', () async {
    final projected = <JournalRecord>[];
    final durable = FileJournal.memory('dev-a');
    final pair = await _linked(durableA: durable, onProjectedA: projected.add);
    final a = pair.$1;
    final b = pair.$2;
    final beforeJournal = a.journal.length;
    final beforeBlocks = a.hypercore.blocks.length;
    await b.transport.send(
      _peerA,
      TransportChannel.replication,
      jsonPayload(
        _replFrame(
          kind: 'messageEnvelopeCreated',
          writerDeviceId: 'c',
          fields: {
            'eventId': 'forged-c',
            'conversationId': _peerB,
            'senderIdentity': _peerB,
            'senderDeviceId': 'c',
            'logicalSequence': 1,
            'createdAt': 1,
            'encryptedEnvelope': base64Encode(utf8.encode('v2:x:y:z')),
          },
        ),
      ),
    );
    await _pump();
    expect(a.journal.length, beforeJournal);
    expect(a.hypercore.blocks.length, beforeBlocks);
    expect(
      a.journal.records.any((r) => r.fields['eventId'] == 'forged-c'),
      isFalse,
    );
    expect(
      a.hypercore.blocks.any((r) => r.fields['eventId'] == 'forged-c'),
      isFalse,
    );
    expect(projected.any((r) => r.fields['eventId'] == 'forged-c'), isFalse);
    final replay = await durable.replay();
    expect(
      replay.records.any((r) => r.fields['eventId'] == 'forged-c'),
      isFalse,
    );
    await a.detach();
    await b.detach();
  });

  test(
    'cross-conversation tombstone and expiry from a contact are dropped',
    () async {
      final projected = <JournalRecord>[];
      final pair = await _linked(onProjectedA: projected.add);
      final a = pair.$1;
      final b = pair.$2;
      await b.transport.send(
        _peerA,
        TransportChannel.replication,
        jsonPayload(
          _replFrame(
            kind: 'messageTombstoned',
            writerDeviceId: 'dev-b',
            fields: {
              'eventId': 'tomb-ac',
              'conversationId': _peerC,
              'createdAt': 1,
            },
          ),
        ),
      );
      await b.transport.send(
        _peerA,
        TransportChannel.replication,
        jsonPayload(
          _replFrame(
            kind: 'attachmentExpired',
            writerDeviceId: 'dev-b',
            fields: {
              'eventId': 'att-ac',
              'conversationId': _peerC,
              'createdAt': 1,
            },
          ),
        ),
      );
      await _pump();
      expect(
        a.journal.records.any((r) => r.fields['eventId'] == 'tomb-ac'),
        isFalse,
      );
      expect(
        a.journal.records.any((r) => r.fields['eventId'] == 'att-ac'),
        isFalse,
      );
      expect(
        a.hypercore.blocks.any(
          (r) =>
              r.fields['eventId'] == 'tomb-ac' ||
              r.fields['eventId'] == 'att-ac',
        ),
        isFalse,
      );
      expect(
        projected.any(
          (r) =>
              r.fields['eventId'] == 'tomb-ac' ||
              r.fields['eventId'] == 'att-ac',
        ),
        isFalse,
      );
      await a.detach();
      await b.detach();
    },
  );

  test(
    'foreign contactBlocked is dropped; signed own-device is applied',
    () async {
      final blocked = <String>{};
      final pair = await _linked(
        isBlockedA: blocked.contains,
        onBlockedA: (id, on) {
          if (on) {
            blocked.add(id);
          } else {
            blocked.remove(id);
          }
        },
      );
      final a = pair.$1;
      final b = pair.$2;
      await b.transport.send(
        _peerA,
        TransportChannel.replication,
        jsonPayload(
          _replFrame(
            kind: 'contactBlocked',
            writerDeviceId: 'dev-b',
            fields: {
              'conversationId': _peerC,
              'peerId': _peerC,
              'blocked': true,
              'createdAt': 1,
            },
          ),
        ),
      );
      await _pump();
      expect(blocked.contains(_peerC), isFalse);
      expect(a.isBlocked(_peerC), isFalse);
      expect(
        a.journal.records.any(
          (r) => r.kind == ReplicationEventKind.contactBlocked,
        ),
        isFalse,
      );

      final own = await _ownDevicePair(blocked: blocked);
      final phone = own.$1;
      final tablet = own.$2;
      final fields = <String, Object?>{
        'conversationId': _peerC,
        'peerId': _peerC,
        'blocked': true,
        'createdAt': 2,
      };
      fields['signature'] = base64Encode(
        signP256Ecdsa(
          _idA,
          canonicalReplicationRecordBytes(
            kind: ReplicationEventKind.contactBlocked,
            writerDeviceId: 'dev-a2',
            fields: fields,
          ),
        ),
      );
      await tablet.transport.send(
        _peerA,
        TransportChannel.replication,
        jsonPayload(
          _replFrame(
            kind: 'contactBlocked',
            writerDeviceId: 'dev-a2',
            fields: fields,
          ),
        ),
      );
      await _pump(80);
      expect(blocked.contains(_peerC), isTrue);
      expect(
        phone.journal.records.any(
          (r) =>
              r.kind == ReplicationEventKind.contactBlocked &&
              r.fields['peerId'] == _peerC,
        ),
        isTrue,
      );
      await a.detach();
      await b.detach();
      await phone.detach();
      await tablet.detach();
    },
  );

  test(
    'deviceRevoked from foreign contact is dropped; signed own-device applies; unsigned drops',
    () async {
      final devices = DeviceRegistry()
        ..authorize(
          AuthorizedDevice(
            deviceId: 'phone-old',
            transportPublicKey: List<int>.generate(32, (i) => 3),
            hypercorePublicKey: List<int>.generate(32, (i) => 4),
            name: 'old',
            kind: 'phone',
            createdAt: 1,
            status: DeviceStatus.active,
            ownerPeerId: _peerA,
          ),
        );
      final pair = await _linked(devicesA: devices);
      final a = pair.$1;
      final b = pair.$2;
      await b.transport.send(
        _peerA,
        TransportChannel.replication,
        jsonPayload(
          _replFrame(
            kind: 'deviceRevoked',
            writerDeviceId: 'dev-b',
            fields: {'deviceId': 'phone-old', 'createdAt': 1},
          ),
        ),
      );
      await _pump();
      expect(devices.isRevoked('phone-old'), isFalse);
      expect(
        a.journal.records.any(
          (r) => r.kind == ReplicationEventKind.deviceRevoked,
        ),
        isFalse,
      );

      final ownDevices = DeviceRegistry()
        ..authorize(
          AuthorizedDevice(
            deviceId: 'dev-a',
            transportPublicKey: List<int>.generate(32, (i) => 3),
            hypercorePublicKey: List<int>.generate(32, (i) => 4),
            name: 'phone',
            kind: 'phone',
            createdAt: 1,
            status: DeviceStatus.active,
            ownerPeerId: _peerA,
            transportPeerId: _peerA,
          ),
        )
        ..authorize(
          AuthorizedDevice(
            deviceId: 'dev-a2',
            transportPublicKey: List<int>.generate(32, (i) => 5),
            hypercorePublicKey: List<int>.generate(32, (i) => 6),
            name: 'tablet',
            kind: 'tablet',
            createdAt: 1,
            status: DeviceStatus.active,
            ownerPeerId: _peerA,
            transportPeerId: 'ORBIT-A2A2A2A2A2A2A2A2',
          ),
        )
        ..authorize(
          AuthorizedDevice(
            deviceId: 'phone-old',
            transportPublicKey: List<int>.generate(32, (i) => 7),
            hypercorePublicKey: List<int>.generate(32, (i) => 8),
            name: 'old',
            kind: 'phone',
            createdAt: 1,
            status: DeviceStatus.active,
            ownerPeerId: _peerA,
          ),
        );
      final own = await _ownDevicePair(devices: ownDevices);
      final phone = own.$1;
      final tablet = own.$2;

      await tablet.transport.send(
        _peerA,
        TransportChannel.replication,
        jsonPayload(
          _replFrame(
            kind: 'deviceRevoked',
            writerDeviceId: 'dev-a2',
            fields: {'deviceId': 'phone-old', 'createdAt': 3},
          ),
        ),
      );
      await _pump(80);
      expect(ownDevices.isRevoked('phone-old'), isFalse);
      expect(
        phone.journal.records.any(
          (r) =>
              r.kind == ReplicationEventKind.deviceRevoked &&
              r.fields['deviceId'] == 'phone-old',
        ),
        isFalse,
      );

      final signed = <String, Object?>{'deviceId': 'phone-old', 'createdAt': 4};
      signed['signature'] = base64Encode(
        signP256Ecdsa(
          _idA,
          canonicalReplicationRecordBytes(
            kind: ReplicationEventKind.deviceRevoked,
            writerDeviceId: 'dev-a2',
            fields: signed,
          ),
        ),
      );
      await tablet.transport.send(
        _peerA,
        TransportChannel.replication,
        jsonPayload(
          _replFrame(
            kind: 'deviceRevoked',
            writerDeviceId: 'dev-a2',
            fields: signed,
          ),
        ),
      );
      await _pump(80);
      expect(ownDevices.isRevoked('phone-old'), isTrue);
      expect(
        phone.journal.records.any(
          (r) =>
              r.kind == ReplicationEventKind.deviceRevoked &&
              r.fields['deviceId'] == 'phone-old',
        ),
        isTrue,
      );
      await a.detach();
      await b.detach();
      await phone.detach();
      await tablet.detach();
    },
  );

  test(
    'unauthorized room membership from a non-host is dropped; host applies',
    () async {
      final pair = await _linked();
      final a = pair.$1;
      final b = pair.$2;
      expect(
        await a.sendAutobaseEvent(
          _peerB,
          const RoomEvent(
            writerId: 'dev-a',
            seq: 0,
            kind: 'membership',
            payload: {
              'roomId': 'room-host',
              'peerId': _peerA,
              'action': 'join',
              'displayName': 'A',
            },
          ),
        ),
        isTrue,
      );
      await _pump();
      expect(b.rooms.state.members[_peerA], 'A');

      expect(
        await b.sendAutobaseEvent(
          _peerA,
          const RoomEvent(
            writerId: 'dev-b',
            seq: 5,
            kind: 'membership',
            payload: {
              'roomId': 'room-host',
              'peerId': _peerC,
              'action': 'join',
              'displayName': 'C',
            },
          ),
        ),
        isFalse,
      );
      await b.transport.send(
        _peerA,
        TransportChannel.replication,
        jsonPayload(
          _replFrame(
            kind: 'roomMembershipChanged',
            writerDeviceId: 'dev-b',
            fields: {
              'roomId': 'room-host',
              'peerId': _peerC,
              'action': 'join',
              'displayName': 'C',
              'writerId': 'dev-b',
              'seq': 5,
              'createdAt': 1,
            },
          ),
        ),
      );
      await _pump();
      expect(a.rooms.state.members.containsKey(_peerC), isFalse);
      expect(b.rooms.state.members.containsKey(_peerC), isFalse);
      expect(
        a.journal.records.any((r) => r.fields['peerId'] == _peerC),
        isFalse,
      );

      expect(
        a.sendRoomPacket(_peerB, {
          'type': 'room_join',
          'roomId': 'room-host',
          'guestPeerId': _peerB,
          'guestName': 'B',
        }),
        isTrue,
      );
      await _pump();
      expect(a.rooms.state.members[_peerB], 'B');
      expect(b.rooms.state.members[_peerB], 'B');

      expect(
        b.sendRoomPacket(_peerA, {
          'type': 'room_join',
          'roomId': 'room-host',
          'abWriter': 'dev-a',
          'guestPeerId': _peerC,
          'guestName': 'C',
        }),
        isTrue,
      );
      await _pump();
      expect(a.rooms.state.members.containsKey(_peerC), isFalse);
      expect(kRoomsApplicationE2eImplemented, isFalse);
      await a.detach();
      await b.detach();
    },
  );

  test('replication flush to a new peer is conversation-scoped', () async {
    final secret = List<int>.generate(32, (i) => 9);
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put(_peerA, secret)
      ..put(_peerB, secret);
    await pair.$1.start(
      TransportLocalConfiguration(peerId: _peerA, discoverySecret: secret),
    );
    await pair.$2.start(
      TransportLocalConfiguration(peerId: _peerB, discoverySecret: secret),
    );
    await pair.$1.publish(await _bind('dev-a', spki: _spkiA, pair: _idA));
    await pair.$2.publish(await _bind('dev-b', spki: _spkiB, pair: _idB));
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('dev-a'),
      selfPeerId: () => _peerA,
      selfDeviceId: 'dev-a',
      secrets: secrets,
      isBlocked: (_) => false,
      tofuCheck: _allowTofu,
      ownIdentityPublicKey: () => _spkiA,
      onPacket: (_, __) async {},
    )..attach();
    a.hypercore.append(
      JournalRecord(
        seq: 0,
        writerDeviceId: 'dev-a',
        kind: ReplicationEventKind.messageEnvelopeCreated,
        fields: {
          'eventId': 'env-b',
          'conversationId': _peerB,
          'senderIdentity': _peerA,
          'senderDeviceId': 'dev-a',
          'logicalSequence': 1,
          'createdAt': 1,
          'encryptedEnvelope': utf8.encode('v2:aaa:bbb:ccc'),
        },
      ),
    );
    a.hypercore.append(
      JournalRecord(
        seq: 1,
        writerDeviceId: 'dev-a',
        kind: ReplicationEventKind.messageEnvelopeCreated,
        fields: {
          'eventId': 'env-c',
          'conversationId': _peerC,
          'senderIdentity': _peerA,
          'senderDeviceId': 'dev-a',
          'logicalSequence': 2,
          'createdAt': 2,
          'encryptedEnvelope': utf8.encode('v2:ddd:eee:fff'),
        },
      ),
    );
    a.hypercore.append(
      JournalRecord(
        seq: 2,
        writerDeviceId: 'dev-a',
        kind: ReplicationEventKind.roomMembershipChanged,
        fields: {
          'roomId': 'room-private',
          'peerId': _peerC,
          'action': 'join',
          'displayName': 'C',
          'writerId': 'dev-a',
          'seq': 0,
          'createdAt': 3,
        },
      ),
    );
    a.hypercore.append(
      JournalRecord(
        seq: 3,
        writerDeviceId: 'dev-a',
        kind: ReplicationEventKind.contactBlocked,
        fields: {
          'conversationId': _peerC,
          'peerId': _peerC,
          'blocked': true,
          'createdAt': 4,
        },
      ),
    );
    final b = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('dev-b'),
      selfPeerId: () => _peerB,
      selfDeviceId: 'dev-b',
      secrets: secrets,
      isBlocked: (_) => false,
      tofuCheck: _allowTofu,
      onPacket: (_, __) async {},
    )..attach();
    await pair.$1.connect(const PeerDescriptor(peerId: _peerB));
    await _awaitAuth(a, b);
    await _pump();
    final sent = pair.$1.sentReplicationFrames;
    expect(sent, isNotEmpty);
    expect(
      sent.every((f) {
        final fields = f['fields'];
        if (fields is! Map) return false;
        final kind = f['kind'];
        if (kind == 'contactBlocked') return false;
        if (kind == 'messageEnvelopeCreated') {
          return fields['conversationId'] == _peerB;
        }
        if (kind == 'roomMembershipChanged') {
          return fields['peerId'] == _peerB;
        }
        return true;
      }),
      isTrue,
    );
    expect(sent.any((f) => (f['fields'] as Map)['eventId'] == 'env-b'), isTrue);
    expect(
      sent.any((f) => (f['fields'] as Map)['eventId'] == 'env-c'),
      isFalse,
    );
    expect(sent.any((f) => f['kind'] == 'contactBlocked'), isFalse);
    await a.detach();
    await b.detach();
  });

  test('local block list does not reach a foreign contact', () async {
    final pair = await _linked();
    final a = pair.$1;
    final b = pair.$2;
    (a.transport as LoopbackOrbitsTransport).sentReplicationFrames.clear();
    a.journalContactBlocked(peerId: _peerC, blocked: true);
    await _pump();
    expect(
      (a.transport as LoopbackOrbitsTransport).sentReplicationFrames.any(
        (f) => f['kind'] == 'contactBlocked',
      ),
      isFalse,
    );
    expect(
      b.journal.records.any(
        (r) => r.kind == ReplicationEventKind.contactBlocked,
      ),
      isFalse,
    );
    await a.detach();
    await b.detach();
  });

  test('rejected replication is absent after FileJournal replay', () async {
    final durable = FileJournal.memory('dev-a');
    final pair = await _linked(durableA: durable);
    final a = pair.$1;
    final b = pair.$2;
    await b.transport.send(
      _peerA,
      TransportChannel.replication,
      jsonPayload(
        _replFrame(
          kind: 'messageTombstoned',
          writerDeviceId: 'c',
          fields: {
            'eventId': 'reject-me',
            'conversationId': _peerB,
            'createdAt': 1,
          },
        ),
      ),
    );
    await _pump();
    expect(
      a.journal.records.any((r) => r.fields['eventId'] == 'reject-me'),
      isFalse,
    );
    final afterReject = await durable.replay();
    expect(
      afterReject.records.any((r) => r.fields['eventId'] == 'reject-me'),
      isFalse,
    );

    await b.transport.send(
      _peerA,
      TransportChannel.replication,
      jsonPayload(
        _replFrame(
          kind: 'deliveryAcknowledged',
          writerDeviceId: 'dev-b',
          fields: {
            'eventId': 'ack-ok',
            'conversationId': _peerB,
            'createdAt': 2,
          },
        ),
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline) &&
        !a.journal.records.any((r) => r.fields['eventId'] == 'ack-ok')) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    expect(
      a.journal.records.any((r) => r.fields['eventId'] == 'ack-ok'),
      isTrue,
    );
    await a.verifyLiveMatchesReplay();
    final afterAccept = await durable.replay();
    expect(
      afterAccept.records.any((r) => r.fields['eventId'] == 'ack-ok'),
      isTrue,
    );
    expect(
      afterAccept.records.any((r) => r.fields['eventId'] == 'reject-me'),
      isFalse,
    );
    await a.detach();
    await b.detach();
  });
}

Future<void> _awaitAuth(DualStackBridge a, DualStackBridge b) async {
  for (var i = 0; i < 80; i++) {
    if (a.authenticated.contains(_peerB) && b.authenticated.contains(_peerA)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

Future<(DualStackBridge, DualStackBridge)> _linked({
  FileJournal? durableA,
  DeviceRegistry? devicesA,
  bool Function(String peerId)? isBlockedA,
  void Function(String peerId, bool blocked)? onBlockedA,
  void Function(JournalRecord record)? onProjectedA,
}) async {
  setHyperswarmRollout(HyperswarmRollout.internal);
  final secret = List<int>.generate(32, (i) => 9);
  final pair = loopbackPair();
  final secrets = DiscoverySecretStore()
    ..put(_peerA, secret)
    ..put(_peerB, secret);
  await pair.$1.start(
    TransportLocalConfiguration(peerId: _peerA, discoverySecret: secret),
  );
  await pair.$2.start(
    TransportLocalConfiguration(peerId: _peerB, discoverySecret: secret),
  );
  await pair.$1.publish(await _bind('dev-a', spki: _spkiA, pair: _idA));
  await pair.$2.publish(await _bind('dev-b', spki: _spkiB, pair: _idB));
  final a = DualStackBridge(
    transport: pair.$1,
    journal: MemoryJournal('dev-a'),
    durableJournal: durableA,
    selfPeerId: () => _peerA,
    selfDeviceId: 'dev-a',
    secrets: secrets,
    devices: devicesA,
    isBlocked: isBlockedA ?? (_) => false,
    tofuCheck: _allowTofu,
    ownIdentityPublicKey: () => _spkiA,
    verifyRecord: verifyWithRemoteSpki,
    onReplicatedContactBlocked: onBlockedA,
    onReplicationAccepted: onProjectedA,
    onPacket: (_, __) async {},
  )..attach();
  final b = DualStackBridge(
    transport: pair.$2,
    journal: MemoryJournal('dev-b'),
    selfPeerId: () => _peerB,
    selfDeviceId: 'dev-b',
    secrets: secrets,
    isBlocked: (_) => false,
    tofuCheck: _allowTofu,
    ownIdentityPublicKey: () => _spkiB,
    onPacket: (_, __) async {},
  )..attach();
  await pair.$1.connect(const PeerDescriptor(peerId: _peerB));
  await _awaitAuth(a, b);
  return (a, b);
}

Future<(DualStackBridge, DualStackBridge)> _ownDevicePair({
  Set<String>? blocked,
  DeviceRegistry? devices,
}) async {
  setHyperswarmRollout(HyperswarmRollout.internal);
  final localSecret = List<int>.generate(32, (i) => 40 + i);
  final pair = loopbackPair();
  final registry =
      devices ??
      (DeviceRegistry()
        ..authorize(
          AuthorizedDevice(
            deviceId: 'dev-a',
            transportPublicKey: List<int>.generate(32, (i) => 3),
            hypercorePublicKey: List<int>.generate(32, (i) => 4),
            name: 'phone',
            kind: 'phone',
            createdAt: 1,
            status: DeviceStatus.active,
            ownerPeerId: _peerA,
            transportPeerId: _peerA,
          ),
        )
        ..authorize(
          AuthorizedDevice(
            deviceId: 'dev-a2',
            transportPublicKey: List<int>.generate(32, (i) => 5),
            hypercorePublicKey: List<int>.generate(32, (i) => 6),
            name: 'tablet',
            kind: 'tablet',
            createdAt: 1,
            status: DeviceStatus.active,
            ownerPeerId: _peerA,
            transportPeerId: 'ORBIT-A2A2A2A2A2A2A2A2',
          ),
        ));
  final secrets = DiscoverySecretStore()
    ..put(_peerA, localSecret)
    ..put('ORBIT-A2A2A2A2A2A2A2A2', localSecret);
  await pair.$1.start(
    TransportLocalConfiguration(peerId: _peerA, discoverySecret: localSecret),
  );
  await pair.$2.start(
    TransportLocalConfiguration(
      peerId: 'ORBIT-A2A2A2A2A2A2A2A2',
      discoverySecret: localSecret,
    ),
  );
  await pair.$1.publish(await _bind('dev-a', spki: _spkiA, pair: _idA));
  await pair.$2.publish(await _bind('dev-a2', spki: _spkiA, pair: _idA));
  List<int>? sign(List<int> canonical) => signP256Ecdsa(_idA, canonical);
  final phone = DualStackBridge(
    transport: pair.$1,
    journal: MemoryJournal('dev-a'),
    selfPeerId: () => _peerA,
    selfDeviceId: 'dev-a',
    secrets: secrets,
    devices: registry,
    isBlocked: blocked?.contains ?? (_) => false,
    tofuCheck: _allowTofu,
    ownIdentityPublicKey: () => _spkiA,
    signRecord: sign,
    verifyRecord: verifyWithRemoteSpki,
    onReplicatedContactBlocked: (id, on) {
      if (blocked == null) return;
      if (on) {
        blocked.add(id);
      } else {
        blocked.remove(id);
      }
    },
    onPacket: (_, __) async {},
  )..attach();
  final tablet = DualStackBridge(
    transport: pair.$2,
    journal: MemoryJournal('dev-a2'),
    selfPeerId: () => 'ORBIT-A2A2A2A2A2A2A2A2',
    selfDeviceId: 'dev-a2',
    secrets: secrets,
    devices: registry,
    isBlocked: (_) => false,
    tofuCheck: _allowTofu,
    ownIdentityPublicKey: () => _spkiA,
    signRecord: sign,
    verifyRecord: verifyWithRemoteSpki,
    onPacket: (_, __) async {},
  )..attach();
  await pair.$1.connect(const PeerDescriptor(peerId: 'ORBIT-A2A2A2A2A2A2A2A2'));
  for (var i = 0; i < 80; i++) {
    if (phone.authenticated.contains('ORBIT-A2A2A2A2A2A2A2A2') &&
        tablet.authenticated.contains(_peerA)) {
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
  return (phone, tablet);
}
