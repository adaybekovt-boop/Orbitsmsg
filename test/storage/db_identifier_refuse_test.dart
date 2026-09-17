// Locator backstops: URL-shaped identifier VALUES must not persist.
// Matches saveMessage (`id.contains('://') || peerId.contains('://')`).
// Avatar *data* URLs (`data:image/...`) stay allowed; only peerId is gated.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;

const _avatarUrl =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1'
    'HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  late OrbitsDatabase database;

  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 9 + 4) & 0xff));
  });

  tearDown(() async {
    clearVaultKek();
    await closeOrbitsDatabase();
  });

  test('ratchet and session locators refuse :// peerId', () async {
    expect(
      await db.saveRatchetState({'peerId': 'https://evil', 'Ns': 1}),
      isFalse,
    );
    expect(await db.loadRatchetState('https://evil'), isNull);
    expect(await db.deleteRatchetState('https://evil'), isFalse);
    expect(await database.select(database.ratchetsTable).get(), isEmpty);

    expect(await db.saveSessionKey('https://evil', 'c2VjcmV0'), isFalse);
    expect(await database.select(database.sessionKeysTable).get(), isEmpty);

    expect(
      await db.saveRatchetState({'peerId': 'ORBIT-PEER01', 'Ns': 1}),
      isTrue,
    );
    expect(await db.loadRatchetState('ORBIT-PEER01'), isNotNull);
    expect(await db.saveSessionKey('ORBIT-PEER01', 'c2VjcmV0'), isTrue);
  });

  test('savePeer refuses a URL-shaped id', () async {
    expect(await db.savePeer({'id': 'https://evil', 'displayName': 'x'}), isFalse);
    expect(await db.getPeer('https://evil'), isNull);
    expect(await db.savePeer({'id': 'ORBIT-PEER01', 'displayName': 'ok'}), isTrue);
    expect((await db.getPeer('ORBIT-PEER01'))?['displayName'], 'ok');
  });

  test('saveRoom refuses URL room id or hostPeerId', () async {
    await db.saveRoom({
      'id': 'https://evil',
      'name': 'Nope',
      'hostPeerId': 'ORBIT-HOST01',
      'isHost': true,
    });
    await db.saveRoom({
      'id': 'ORBIT-ROOM01',
      'name': 'Nope',
      'hostPeerId': 'https://evil',
      'isHost': true,
    });
    expect(await database.select(database.roomsTable).get(), isEmpty);
    expect(await database.select(database.roomChannelsTable).get(), isEmpty);

    await db.saveRoom({
      'id': 'ORBIT-ROOM01',
      'name': 'Ok',
      'hostPeerId': 'ORBIT-HOST01',
      'isHost': false,
    });
    expect(await database.select(database.roomsTable).get(), hasLength(1));
  });

  test('room member and channel locators refuse :// and skip hostile members',
      () async {
    await db.saveRoom({
      'id': 'ORBIT-ROOM01',
      'name': 'Ok',
      'hostPeerId': 'ORBIT-HOST01',
      'isHost': false,
    });

    await db.saveRoomMember({
      'roomId': 'https://evil',
      'peerId': 'ORBIT-MEMBER1',
      'displayName': 'Bad',
    });
    await db.saveRoomMember({
      'roomId': 'ORBIT-ROOM01',
      'peerId': 'https://evil',
      'displayName': 'Bad',
    });
    expect(await db.getRoomMembers('ORBIT-ROOM01'), isEmpty);

    await db.replaceRoomMembers('https://evil', [
      {'peerId': 'ORBIT-MEMBER1', 'displayName': 'A'},
    ]);
    expect(await db.getRoomMembers('https://evil'), isEmpty);

    await db.replaceRoomMembers('ORBIT-ROOM01', [
      {'peerId': 'https://evil', 'displayName': 'Bad'},
      {'peerId': 'ORBIT-MEMBER1', 'displayName': 'Good'},
    ]);
    final members = await db.getRoomMembers('ORBIT-ROOM01');
    expect(members, hasLength(1));
    expect(members.single['peerId'], 'ORBIT-MEMBER1');

    expect(await db.createChannel('https://evil', 'general', 'text'), isEmpty);
    await db.upsertRoomChannel({
      'id': 'https://evil',
      'roomId': 'ORBIT-ROOM01',
      'name': 'x',
      'type': 'text',
    });
    await db.upsertRoomChannel({
      'id': 'ch-ok',
      'roomId': 'https://evil',
      'name': 'x',
      'type': 'text',
    });
    expect(await db.getRoomChannels('ORBIT-ROOM01'), isEmpty);

    await db.upsertRoomChannel({
      'id': 'ch-ok',
      'roomId': 'ORBIT-ROOM01',
      'name': 'general',
      'type': 'text',
    });
    expect(await db.getRoomChannels('ORBIT-ROOM01'), hasLength(1));
  });

  test('voice and avatar locators refuse ://; avatar data URL still allowed',
      () async {
    expect(await db.saveVoiceBlob('https://evil', const [1, 2, 3]), isFalse);
    expect(await database.select(database.voiceBlobsTable).get(), isEmpty);
    expect(await db.saveVoiceBlob('v1', const [1, 2, 3]), isTrue);

    expect(await db.saveAvatar('https://evil', _avatarUrl), isFalse);
    expect(await db.getAvatar('https://evil'), isNull);
    expect(await database.select(database.avatarsTable).get(), isEmpty);

    expect(await db.saveAvatar('ORBIT-AVA001', _avatarUrl), isTrue);
    expect(await db.getAvatar('ORBIT-AVA001'), _avatarUrl);
  });
}
