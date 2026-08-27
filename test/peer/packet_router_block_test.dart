// R04 — block-list is enforced at packet-router ingress, before Drop /
// rooms / heartbeat / decrypt.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/messaging/message_protocol.dart';
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
      notifyNewMessage: (
          {required String from, required String text, required String tag}) {},
      hapticMessage: () {},
      playReceiveSound: () {},
      isAppInForeground: () => true,
    );

void main() {
  const peer = 'ORBIT-BLOCKED';

  test('blocked peer: drop / room / heartbeat never reach handlers', () async {
    final dropSeen = <Object>[];
    final roomSeen = <Object>[];
    var heartbeat = 0;
    final handler = createPacketHandler(
      'reliable',
      peer,
      PacketRouterCtx(
        conn: (_) {},
        reliable: _reliable(),
        ephemeral: EphemeralInboundCtx(
          applyTyping: (_) {},
          onHeartbeat: () => heartbeat++,
        ),
        flushOutbox: () {},
        dropInbound: (_, packet) => dropSeen.add(packet),
        dropAllowed: (_) => true,
        roomInbound: (_, packet) => roomSeen.add(packet),
        isBlocked: (id) => id == peer,
      ),
    );

    await handler(<String, Object?>{
      'type': 'file-start',
      'fileId': 'abc',
      'size': 10,
    });
    await handler(Uint8List(64));
    await handler(<String, Object?>{
      'type': 'room_msg',
      'roomId': 'r',
      'channelId': 'c',
      'text': 'hi',
    });
    expect(dropSeen, isEmpty);
    expect(roomSeen, isEmpty);

    final eph = createPacketHandler(
      'ephemeral',
      peer,
      PacketRouterCtx(
        conn: (_) {},
        reliable: _reliable(),
        ephemeral: EphemeralInboundCtx(
          applyTyping: (_) {},
          onHeartbeat: () => heartbeat++,
        ),
        flushOutbox: () {},
        isBlocked: (id) => id == peer,
      ),
    );
    await eph(<String, Object?>{'type': 'hb'});
    expect(heartbeat, 0);
  });
}
