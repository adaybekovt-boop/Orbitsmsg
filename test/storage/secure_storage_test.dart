// Fail-closed at-rest storage (audit P0 item 2) + targeted blob cleanup
// (audit P1 item 6).

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;

const _peerA = 'ORBIT-AAAAAA';
const _peerB = 'ORBIT-BBBBBB';

Future<bool> _msg(String id, String peerId) => db.saveMessage({
      'id': id,
      'peerId': peerId,
      'timestamp': 1,
      'direction': 'in',
      'status': 'delivered',
      'payload': {'text': id},
    });

void main() {
  late OrbitsDatabase database;

  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 5 + 1) & 0xff));
  });

  tearDown(() async {
    clearVaultKek();
    await closeOrbitsDatabase();
  });

  group('fail-closed when vault locked (item 2)', () {
    test('saveMessage refuses to write plaintext while locked', () async {
      clearVaultKek();
      expect(await _msg('M1', _peerA), isFalse,
          reason: 'no plaintext content on disk while locked');
      expect(await database.select(database.messagesTable).get(), isEmpty);
    });

    test('savePeer refuses to write plaintext while locked', () async {
      clearVaultKek();
      expect(await db.savePeer({'id': _peerA, 'lastSeenAt': 1}), isFalse);
      expect(await database.select(database.peersTable).get(), isEmpty);
    });

    test('unlocked write succeeds and the on-disk blob is encrypted', () async {
      expect(await _msg('M2', _peerA), isTrue);
      expect(await db.getMessageById('M2'), isNotNull);
      final rows = await database.select(database.messagesTable).get();
      expect(rows, hasLength(1));
      // Encrypted blob frame magic is 'OB1' (0x4F…) — never '{' (plaintext JSON).
      expect(rows.first.data.first, 0x4F);
    });
  });

  group('targeted blob cleanup (item 6)', () {
    setUp(() async {
      for (final m in ['A1', 'A2']) {
        await _msg(m, _peerA);
        await db.saveVoiceBlob(m, [1, 2, 3], mime: 'audio/webm', duration: 1);
      }
      await _msg('B1', _peerB);
      await db.saveVoiceBlob('B1', [4, 5, 6], mime: 'audio/webm', duration: 1);
    });

    Future<Set<String>> blobIds() async =>
        (await database.select(database.voiceBlobsTable).get())
            .map((r) => r.id)
            .toSet();

    test('deleteMessageRow drops only that message blob', () async {
      await db.deleteMessageRow('A1');
      expect(await blobIds(), {'A2', 'B1'});
    });

    test('clearMessagesForPeer drops only that peer blobs', () async {
      final n = await db.clearMessagesForPeer(_peerA);
      expect(n, 2);
      expect(await blobIds(), {'B1'});
    });
  });
}
