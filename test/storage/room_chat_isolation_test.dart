// Phase 3 — rooms must NOT corrupt normal 1:1 chat state.
//
// Room messages are stored in the shared `messages` table tagged with a
// `room_id`/`channel_id`. Before the fix the 1:1 queries filtered only by
// `peer_id`, so a room message authored by a peer who is also a 1:1 contact
// leaked into their private DM thread, and a room-only author appeared as a
// phantom conversation. These tests lock in the `room_id IS NULL` isolation.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;

void main() {
  late OrbitsDatabase database;

  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 7 + 1) & 0xff));
  });

  tearDown(() async {
    clearVaultKek();
    await closeOrbitsDatabase();
  });

  test('room messages are excluded from 1:1 chat + conversation queries',
      () async {
    const peer = 'ORBIT-PEER01'; // a contact who is ALSO in our room
    const roomId = 'ORBIT-HOST01';
    const roomOnly = 'ORBIT-ROOMONLY'; // a room member we never DM'd

    // Host room so a real text channel id exists.
    await db.saveRoom({
      'id': roomId,
      'name': 'R',
      'hostPeerId': roomId,
      'isHost': true,
      'createdAt': 1,
      'status': 'active',
    });
    final channels = await db.watchChannels(roomId).first;
    final channelId =
        channels.firstWhere((c) => c['type'] == 'text')['id'] as String;

    // A genuine 1:1 DM from `peer`.
    await db.saveMessage({
      'id': 'dm1',
      'peerId': peer,
      'timestamp': 100,
      'direction': 'in',
      'status': 'delivered',
      'payload': {'text': 'private hi'},
    });
    // A ROOM message authored by the same `peer` (also a contact).
    await db.saveMessage({
      'id': 'rm1',
      'peerId': peer,
      'roomId': roomId,
      'channelId': channelId,
      'timestamp': 200,
      'direction': 'in',
      'status': 'delivered',
      'payload': {'kind': 'text', 'text': 'room hi from contact'},
    });
    // A ROOM message from someone we never DM'd.
    await db.saveMessage({
      'id': 'rm2',
      'peerId': roomOnly,
      'roomId': roomId,
      'channelId': channelId,
      'timestamp': 300,
      'direction': 'in',
      'status': 'delivered',
      'payload': {'kind': 'text', 'text': 'room hi from stranger'},
    });

    // 1:1 thread for `peer` shows ONLY the DM — never the room message.
    final dm = await db.watchMessagesForPeer(peer).first;
    expect(dm.map((m) => m['id']), ['dm1']);

    // The channel view shows BOTH room messages (and not the DM).
    final ch = await db.watchChannelMessages(channelId).first;
    expect(ch.map((m) => m['id']), ['rm1', 'rm2']);

    // Conversation list: `peer` exists with the DM as its preview (NOT the
    // later room message), and the room-only author is NOT a phantom chat.
    final metas = await db.watchChatMetas().first;
    final ids = metas.map((m) => m['peerId']).toSet();
    expect(ids, contains(peer));
    expect(ids, isNot(contains(roomOnly)),
        reason: 'a room-only author must not appear as a 1:1 conversation');
    final peerMeta = metas.firstWhere((m) => m['peerId'] == peer);
    expect(peerMeta['lastTs'], 100, reason: 'preview is the DM, not the room msg');
    final lastPayload = (peerMeta['lastData'] as Map?)?['payload'] as Map?;
    expect(lastPayload?['text'], 'private hi');
    expect(peerMeta['unreadCount'], 1,
        reason: 'only the DM counts toward unread, not the room message');
  });
}
