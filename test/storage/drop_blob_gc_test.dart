// R6-05 — Drop file blobs are not message-owned. Clearing an unrelated
// chat (or the startup orphan sweep) must leave them on disk.

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
    await setVaultKek(List<int>.generate(32, (i) => (i * 5 + 2) & 0xff));
  });

  tearDown(() async {
    clearVaultKek();
    await closeOrbitsDatabase();
  });

  test('Drop blob survives clearMessagesForPeer of another chat + sweep',
      () async {
    await db.saveMessage({
      'id': 'msg-chat-1',
      'peerId': 'ORBIT-CHAT01',
      'payload': 'hello',
      'direction': 'in',
    });
    expect(await db.saveFileBlob('msg-chat-1', <int>[1, 2, 3], name: 'a.bin'),
        isTrue);

    const dropId = 'drop-file-xyz';
    expect(
      await db.saveFileBlob(dropId, <int>[9, 8, 7], name: 'photo.jpg'),
      isTrue,
    );
    expect(await db.getFileBlob(dropId), isNotNull,
        reason: 'Drop file must exist before GC');

    await db.clearMessagesForPeer('ORBIT-UNRELATED');
    expect(await db.getFileBlob(dropId), isNotNull,
        reason: 'unrelated chat clear must not delete Drop files');
    expect(await db.getFileBlob('msg-chat-1'), isNotNull,
        reason: 'the other chat\'s attachment is untouched');

    await db.clearMessagesForPeer('ORBIT-CHAT01');
    expect(await db.getFileBlob('msg-chat-1'), isNull,
        reason: 'message-owned blob is swept with its chat');
    expect(await db.getFileBlob(dropId), isNotNull,
        reason: 'Drop blob must survive the chat that did not own it');

    // Startup GC (main.dart calls sweepOrphanBlobs).
    await db.sweepOrphanBlobs();
    expect(await db.getFileBlob(dropId), isNotNull);
    expect((await db.loadDropOwnedBlobIds()).contains(dropId), isTrue);
  });

  test('deleting the Drop blob unregisters it so a later sweep stays clean',
      () async {
    const dropId = 'drop-gone';
    await db.saveFileBlob(dropId, <int>[4, 4, 4]);
    expect((await db.loadDropOwnedBlobIds()).contains(dropId), isTrue);
    await db.deleteFileBlob(dropId);
    expect(await db.getFileBlob(dropId), isNull);
    expect((await db.loadDropOwnedBlobIds()).contains(dropId), isFalse);
    await db.sweepOrphanBlobs();
    expect(await db.getFileBlob(dropId), isNull);
  });
}
