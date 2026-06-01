// Peer persistence — the storage half of "add contact". A scanned/typed
// contact must land in `peers`, show up in the reactive list the chat list
// watches, and a re-add (duplicate) must merge safely rather than crash or
// clobber a user's custom name.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;

void main() {
  setUp(() async {
    setOrbitsDatabase(OrbitsDatabase.forTesting(NativeDatabase.memory()));
    // Peer `data` blobs are encrypted with the vault KEK — set one so the
    // encode/decode round-trip works (mirrors rooms_db_test).
    await setVaultKek(List<int>.generate(32, (i) => (i * 9 + 4) & 0xff));
  });

  tearDown(() async {
    clearVaultKek();
    await closeOrbitsDatabase();
  });

  test('savePeer persists a peer that getPeer reads back', () async {
    const id = 'ORBIT-ABC123';
    final ok = await db.savePeer({
      'id': id,
      'trustLevel': 0,
      'lastSeenAt': 1000,
    });
    expect(ok, isTrue);

    final fetched = await db.getPeer(id);
    expect(fetched, isNotNull);
    expect(fetched!['id'], id);
    expect((fetched['lastSeenAt'] as num).toInt(), 1000);
  });

  test('watchAllPeers emits the newly-saved peer', () async {
    const id = 'ORBIT-DEF456';
    await db.savePeer({'id': id, 'lastSeenAt': 1000});

    final peers = await db.watchAllPeers().first;
    expect(peers.any((p) => p['id'] == id), isTrue);
  });

  test('duplicate savePeer does not crash and merges fields safely', () async {
    const id = 'ORBIT-ABC123';
    // First add.
    await db.savePeer({'id': id, 'lastSeenAt': 1000});
    // User renames locally.
    await db.setPeerCustomName(id, 'Моя кличка');
    // Re-adding the same contact (e.g. re-scanned the QR) bumps lastSeenAt but
    // must NOT wipe the custom name or duplicate the row.
    final ok = await db.savePeer({'id': id, 'lastSeenAt': 2000});
    expect(ok, isTrue);

    final all = await db.getAllPeers();
    expect(all.where((p) => p['id'] == id), hasLength(1),
        reason: 'no duplicate row on re-add');

    final fetched = await db.getPeer(id);
    expect((fetched!['lastSeenAt'] as num).toInt(), 2000,
        reason: 'lastSeenAt updates on re-add');
    expect(fetched['customName'], 'Моя кличка',
        reason: 'local custom name survives a re-add');
  });
}
