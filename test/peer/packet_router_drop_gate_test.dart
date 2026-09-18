// Phase 3.1: Drop / file-transfer frames must not reach the engine before
// a verified wire handshake.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/orbits_drop.dart';
import 'package:orbits_flutter/messaging/message_protocol.dart';
// InboundPersistResult used by the pushMessage stub.
import 'package:orbits_flutter/peer/packet_router.dart';

ReliableInboundCtx _reliable() => ReliableInboundCtx(
  selfPeerId: 'ORBIT-AAAAAA',
  localProfile: () => null,
  seenMsgIds: <String>{},
  pushMessage: (_, __) async => InboundPersistResult.committed,
  updateMessage: (_, __, ___) {},
  setProfilesByPeer: (_) {},
  setMessagesByPeer: (_) {},
  upsertPeer: (_, __) {},
  queueAckStatus: (_, __) {},
  sendEncrypted: (_) {},
  notifyNewMessage:
      ({required String from, required String text, required String tag}) {},
  hapticMessage: () {},
  playReceiveSound: () {},
  isAppInForeground: () => true,
);

EphemeralInboundCtx _ephemeral() =>
    EphemeralInboundCtx(applyTyping: (_) {}, onHeartbeat: () {});

PacketRouterCtx _ctx({
  bool Function(String)? dropAllowed,
  void Function(String, Object)? dropInbound,
  void Function(String, Map<String, Object?>)? dropHandlePacket,
  void Function(String, Map<String, Object?>)? roomInbound,
}) {
  return PacketRouterCtx(
    conn: (_) {},
    reliable: _reliable(),
    ephemeral: _ephemeral(),
    flushOutbox: () {},
    dropInbound: dropInbound,
    dropHandlePacket: dropHandlePacket,
    dropAllowed: dropAllowed,
    roomInbound: roomInbound,
  );
}

void main() {
  const peer = 'ORBIT-BBBBBB';

  group('drop-before-wire gate', () {
    test(
      'unverified peer: file-start and binary never reach dropInbound',
      () async {
        final seen = <Object>[];
        final handler = createPacketHandler(
          'reliable',
          peer,
          _ctx(
            dropAllowed: (_) => false,
            dropInbound: (_, packet) => seen.add(packet),
          ),
        );
        await handler(<String, Object?>{
          'type': 'file-start',
          'fileId': 'abc',
          'size': 10,
        });
        await handler(Uint8List(64));
        expect(seen, isEmpty);
      },
    );

    test('null dropAllowed is fail-closed', () async {
      final seen = <Object>[];
      final handler = createPacketHandler(
        'reliable',
        peer,
        _ctx(dropInbound: (_, packet) => seen.add(packet)),
      );
      await handler(<String, Object?>{'type': 'file-start', 'fileId': 'x'});
      expect(seen, isEmpty);
    });

    test('verified peer: file-start reaches dropInbound', () async {
      final seen = <Object>[];
      final handler = createPacketHandler(
        'reliable',
        peer,
        _ctx(
          dropAllowed: (_) => true,
          dropInbound: (_, packet) => seen.add(packet),
        ),
      );
      final start = <String, Object?>{'type': 'file-start', 'fileId': 'abc'};
      await handler(start);
      expect(seen, hasLength(1));
      expect((seen.first as Map)['type'], 'file-start');
    });

    test('oversized binary is dropped even when allowed', () async {
      final seen = <Object>[];
      final handler = createPacketHandler(
        'reliable',
        peer,
        _ctx(
          dropAllowed: (_) => true,
          dropInbound: (_, packet) => seen.add(packet),
        ),
      );
      await handler(Uint8List(kMaxDropFrameBytes + 1));
      expect(seen, isEmpty);
      await handler(Uint8List(32));
      expect(seen, hasLength(1));
    });

    test('unverified drop-beacon on ephemeral is discarded', () async {
      final seen = <Map<String, Object?>>[];
      final handler = createPacketHandler(
        'ephemeral',
        peer,
        _ctx(
          dropAllowed: (_) => false,
          dropHandlePacket: (_, data) => seen.add(data),
        ),
      );
      await handler(<String, Object?>{'type': 'drop-beacon'});
      expect(seen, isEmpty);
    });

    test('room packets still dispatch when drop is denied', () async {
      final rooms = <Map<String, Object?>>[];
      final handler = createPacketHandler(
        'reliable',
        peer,
        _ctx(
          dropAllowed: (_) => false,
          roomInbound: (_, data) => rooms.add(data),
        ),
      );
      await handler(<String, Object?>{'type': 'room_join', 'roomId': 'r1'});
      expect(rooms, hasLength(1));
      expect(rooms.first['type'], 'room_join');
    });
  });

  group('nested secret refuse', () {
    test('file-start with nested fileKey never reaches dropInbound', () async {
      final seen = <Object>[];
      final handler = createPacketHandler(
        'reliable',
        peer,
        _ctx(
          dropAllowed: (_) => true,
          dropInbound: (_, packet) => seen.add(packet),
        ),
      );
      await handler(<String, Object?>{
        'type': 'file-start',
        'fileId': 'abc',
        'meta': <String, Object?>{'fileKey': 'x'},
      });
      expect(seen, isEmpty);
    });

    test('room_msg with nested fileKey never reaches roomInbound', () async {
      final rooms = <Map<String, Object?>>[];
      final handler = createPacketHandler(
        'reliable',
        peer,
        _ctx(roomInbound: (_, data) => rooms.add(data)),
      );
      await handler(<String, Object?>{
        'type': 'room_msg',
        'roomId': 'r1',
        'text': 'hello',
        'meta': <String, Object?>{'fileKey': 'x'},
      });
      expect(rooms, isEmpty);
    });

    test('legit room_join still reaches roomInbound', () async {
      final rooms = <Map<String, Object?>>[];
      final handler = createPacketHandler(
        'reliable',
        peer,
        _ctx(roomInbound: (_, data) => rooms.add(data)),
      );
      await handler(<String, Object?>{'type': 'room_join', 'roomId': 'r1'});
      expect(rooms, hasLength(1));
    });

    test('chat msg maps are not swallowed by the Drop/room secret gate', () {
      // Reliable chat is ciphertext → dispatchReliablePlaintext, which
      // drops nested sticker secrets but keeps text. The router must not
      // apply a blanket map walk before reliableMiddleware.
      final src = File('lib/peer/packet_router.dart').readAsStringSync();
      final reliable = src
          .split('// Reliable channel: file-transfer traffic first')[1]
          .split('Future<bool> reliableMiddleware')[0];
      expect(reliable, contains('_fileTransferTypes'));
      expect(reliable, contains('isRoomPacket'));
      expect(reliable, contains('replicationValueIsSafe'));
      expect(reliable, contains('reliableMiddleware'));
      final dropGate = reliable.split('if (data is Map && _fileTransferTypes')[1]
          .split('if (data is Map && isRoomPacket')[0];
      expect(dropGate, contains('replicationValueIsSafe'));
      final roomGate = reliable.split('if (data is Map && isRoomPacket')[1]
          .split('if (dropMiddleware')[0];
      expect(roomGate, contains('replicationValueIsSafe'));
      expect(reliable.contains('if (!replicationValueIsSafe(data)) return;'),
          isTrue);
      // No all-maps refuse before the Drop/room type checks.
      final beforeTypes = reliable.split("if (data is Uint8List)")[0];
      expect(beforeTypes.contains('replicationValueIsSafe'), isFalse);
    });

    test('ephemeral typing with nested kek does not applyTyping', () async {
      var typed = false;
      final handler = createPacketHandler(
        'ephemeral',
        peer,
        PacketRouterCtx(
          conn: (_) {},
          reliable: _reliable(),
          ephemeral: EphemeralInboundCtx(
            applyTyping: (_) => typed = true,
            onHeartbeat: () {},
          ),
          flushOutbox: () {},
        ),
      );
      await handler(<String, Object?>{
        'type': 'typing',
        'isTyping': true,
        'extra': <String, Object?>{'kek': 'x'},
      });
      expect(typed, isFalse);
    });
  });
}
