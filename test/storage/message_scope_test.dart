// R07 — room_msg must not overwrite a DM row that shares the same wire id.

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
    await setVaultKek(List<int>.generate(32, (i) => (i * 11 + 2) & 0xff));
  });
  tearDown(() async {
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  test('room_msg with a DM id is rejected or stored under a room key',
      () async {
    const dmId = 'ORBIT-SELF:1000:abcd';
    await db.saveMessage({
      'id': dmId,
      'peerId': 'ORBIT-FRIEND',
      'timestamp': 1000,
      'direction': 'in',
      'status': 'delivered',
      'payload': {'text': 'private dm', 'type': 'text'},
    });

    final roomKey = db.scopedRoomMessageId('room-1', dmId);
    expect(roomKey, isNot(dmId));

    final overwritten = await db.saveMessage({
      'id': dmId,
      'peerId': 'ORBIT-HOST',
      'roomId': 'room-1',
      'channelId': 'general',
      'timestamp': 2000,
      'direction': 'in',
      'status': 'delivered',
      'payload': {'text': 'host overwrite', 'type': 'text'},
    });
    expect(overwritten, isFalse,
        reason: 'DM scope must not be replaced by a room row');

    final dm = await db.getMessageById(dmId);
    expect(dm!['payload'], isA<Map>());
    expect((dm['payload'] as Map)['text'], 'private dm');
    expect(dm['peerId'], 'ORBIT-FRIEND');
    expect(dm['roomId'], anyOf(isNull, ''));

    await db.saveRoom({
      'id': 'room-1',
      'name': 'R',
      'hostPeerId': 'ORBIT-HOST',
      'isHost': true,
      'createdAt': 1,
      'status': 'active',
    });
    final channels = await db.watchChannels('room-1').first;
    final generalId = channels.firstWhere((c) => c['type'] == 'text')['id'];

    final roomOk = await db.saveMessage({
      'id': roomKey,
      'peerId': 'ORBIT-HOST',
      'roomId': 'room-1',
      'channelId': generalId,
      'timestamp': 2000,
      'direction': 'in',
      'status': 'delivered',
      'payload': {'text': 'room text', 'type': 'text'},
    });
    expect(roomOk, isTrue);
    expect((await db.getMessageById(roomKey))!['roomId'], 'room-1');
    expect((await db.getMessageById(dmId))!['payload'], dm['payload']);
  });
}
