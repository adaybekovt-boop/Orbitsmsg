// Phase 1 verification — Discord-style rooms schema (v3).
//
// Exercises the full CRUD cycle against an in-memory DB:
//   • saveRoom (host) → auto-creates the two default channels
//   • saveRoomMember (with a base64 avatar)
//   • saveMessage into #general → watchChannelMessages
//   • watchChannels / watchRoomMembers / watchChannelMessages return the
//     persisted data
//   • deleteRoom → ON DELETE CASCADE reaps channels + members + the channels'
//     message history (relies on `PRAGMA foreign_keys = ON` from
//     `database.dart` beforeOpen).

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
    // Messages persist through the vault-KEK encrypt/decrypt path, so a KEK
    // must be present for the round-trip (mirrors db_secure_storage_test).
    await setVaultKek(List<int>.generate(32, (i) => (i * 7 + 1) & 0xff));
  });

  tearDown(() async {
    clearVaultKek();
    await closeOrbitsDatabase();
  });

  test('room CRUD: default channels, member+avatar, message, CASCADE delete',
      () async {
    const roomId = 'ORBIT-TEST-0001';
    const avatar =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1'
        'HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

    // ── 1. Host creates the room → two default channels auto-provisioned. ──
    await db.saveRoom({
      'id': roomId,
      'name': 'Test Room',
      'hostPeerId': 'ORBIT-HOST01',
      'isHost': true,
      'createdAt': 1000,
      'status': 'active',
    });

    // ── 2. Default channels: text 'general' (#general) + voice 'Голосовой 1'
    //       (🔊 Голосовой 1). The #/🔊 are UI prefixes derived from `type`. ──
    final channels = await db.watchChannels(roomId).first;
    expect(channels, hasLength(2));
    final textCh = channels.firstWhere((c) => c['type'] == 'text');
    final voiceCh = channels.firstWhere((c) => c['type'] == 'voice');
    expect(textCh['name'], 'general'); // rendered as #general
    expect(voiceCh['name'], 'Голосовой 1'); // rendered as 🔊 Голосовой 1
    expect(textCh['position'], 0);
    expect(voiceCh['position'], 1);
    final generalId = textCh['id'] as String;
    expect(generalId, isNotEmpty);

    // Idempotent: re-saving the room must NOT duplicate the default channels.
    await db.saveRoom({'id': roomId, 'name': 'Test Room', 'isHost': true});
    expect(await db.watchChannels(roomId).first, hasLength(2));

    // ── 3. Add a member with a base64 avatar. ──
    await db.saveRoomMember({
      'roomId': roomId,
      'peerId': 'ORBIT-MEMBER1',
      'displayName': 'Тестер',
      'avatarDataUrl': avatar,
      'isOnline': true,
      'joinedAt': 1100,
    });
    final members = await db.watchRoomMembers(roomId).first;
    expect(members, hasLength(1));
    expect(members.first['peerId'], 'ORBIT-MEMBER1');
    expect(members.first['displayName'], 'Тестер');
    expect(members.first['avatarDataUrl'], avatar);
    expect(members.first['isOnline'], true);

    // ── 4. Send a text message into #general. ──
    await db.saveMessage({
      'id': 'room-msg-1',
      'peerId': 'ORBIT-MEMBER1',
      'roomId': roomId,
      'channelId': generalId,
      'timestamp': 1200,
      'direction': 'in',
      'status': 'delivered',
      'payload': {'kind': 'text', 'text': 'Привет, комната! 👋'},
    });
    final msgs = await db.watchChannelMessages(generalId).first;
    expect(msgs, hasLength(1));
    expect((msgs.first['payload'] as Map)['text'], 'Привет, комната! 👋');

    // Sanity: the room + its rows really exist before the cascade.
    expect(await database.select(database.roomsTable).get(), hasLength(1));
    expect(await database.select(database.roomChannelsTable).get(),
        hasLength(2));
    expect(
        await database.select(database.roomMembersTable).get(), hasLength(1));
    expect(await database.select(database.messagesTable).get(), hasLength(1));

    // ── 5. Delete the room → CASCADE removes channels, members, messages. ──
    final deleted = await db.deleteRoom(roomId);
    expect(deleted, isTrue);

    expect(await database.select(database.roomsTable).get(), isEmpty);
    expect(await database.select(database.roomChannelsTable).get(), isEmpty,
        reason: 'channels must cascade-delete with their room');
    expect(await database.select(database.roomMembersTable).get(), isEmpty,
        reason: 'members must cascade-delete with their room');
    expect(await database.select(database.messagesTable).get(), isEmpty,
        reason:
            'channel messages must cascade-delete (messages.channel_id → '
            'room_channels → rooms)');
  });
}
