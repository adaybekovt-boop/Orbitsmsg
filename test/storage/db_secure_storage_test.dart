// End-to-end proof for audit L3: message/peer `data` blobs are encrypted at
// rest under the vault KEK, AND a pre-L3 plaintext row still decodes (lossless
// lazy migration — history is never bricked).

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;
import 'package:orbits_flutter/storage/row_codec.dart';

void main() {
  late OrbitsDatabase database;

  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(
      List<int>.generate(32, (i) => (i * 5 + 3) & 0xff),
    );
  });

  tearDown(() async {
    clearVaultKek();
    await closeOrbitsDatabase();
  });

  test('message round-trips and is encrypted on disk', () async {
    await db.saveMessage({
      'id': 'm1',
      'peerId': 'ORBIT-AAAAAA',
      'timestamp': 1000,
      'direction': 'in',
      'status': 'delivered',
      'payload': {'kind': 'text', 'text': 'секрет 🔒'},
    });

    // Read back through the API — content survives the encrypt/decrypt round.
    final msgs = await db.getMessages('ORBIT-AAAAAA');
    expect(msgs, hasLength(1));
    final payload = msgs.first['payload'] as Map;
    expect(payload['text'], 'секрет 🔒');

    // The raw stored blob must actually be ciphertext, not plaintext JSON.
    final raw = await database.select(database.messagesTable).getSingle();
    expect(isBlobWrapped(raw.data), isTrue,
        reason: 'message data blob should be encrypted at rest');
  });

  test('peer round-trips and is encrypted on disk', () async {
    await db.savePeer({'id': 'ORBIT-BBBBBB', 'displayName': 'Алиса'});
    final peer = await db.getPeer('ORBIT-BBBBBB');
    expect(peer?['displayName'], 'Алиса');

    final raw = await database.select(database.peersTable).getSingle();
    expect(isBlobWrapped(raw.data), isTrue);
  });

  test('a legacy plaintext message row still decodes (migration)', () async {
    // Simulate a pre-L3 row: raw JSON bytes written straight to the column.
    final legacy = encodeRow(<String, Object?>{
      'id': 'old1',
      'peerId': 'ORBIT-CCCCCC',
      'timestamp': 500,
      'direction': 'out',
      'status': 'sent',
      'payload': {'kind': 'text', 'text': 'старое сообщение'},
    });
    expect(isBlobWrapped(legacy), isFalse); // truly plaintext

    await database.into(database.messagesTable).insert(
          MessagesTableCompanion.insert(
            id: 'old1',
            peerId: 'ORBIT-CCCCCC',
            timestamp: 500,
            direction: 'out',
            status: 'sent',
            data: legacy,
          ),
        );

    final got = await db.getMessageById('old1');
    expect(got, isNotNull);
    expect((got!['payload'] as Map)['text'], 'старое сообщение');
  });
}
