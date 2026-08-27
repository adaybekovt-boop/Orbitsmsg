// Round 5 B.2 — encryption must be a property of the key STORE, not of
// caller discipline.
//
// Contract:
//   1. Writing a key/prekey/ratchet row through DriftKeyStore WITHOUT any
//      wrapSecret() call still lands ciphertext in the DB — a raw dump of
//      the `data` column contains no readable JSON / field names / secrets.
//   2. Reading back through the store returns the original map, byte lists
//      included.
//   3. Legacy plaintext rows (written before this change) keep decoding.
//   4. Locked vault → put fails closed (StateError), nothing persisted.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/drift_key_store.dart';
import 'package:orbits_flutter/storage/legacy_seal_migration.dart';

void main() {
  late OrbitsDatabase database;
  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 13 + 7) & 0xff));
    installDriftKeyStore(database: database);
  });
  tearDown(() async {
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  test('raw ratchet row on disk is ciphertext even without caller wrapping',
      () async {
    const secret = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04];
    await keyStore().put('ratchets', {
      'id': 'ratchet-ORBIT-A1B2C3D4E5F60718',
      'peerId': 'ORBIT-A1B2C3D4E5F60718',
      'rootKey': Uint8List.fromList(secret),
      'ns': 5,
    });

    // Raw dump — bypass the store entirely.
    final rows = await (database.select(database.ratchetsTable)).get();
    expect(rows, hasLength(1));
    final raw = rows.first.data;

    // OB1 frame magic (0x4F 0x42 0x31).
    expect(raw[0], 0x4F, reason: 'row must be OB1-sealed at rest');
    expect(raw[1], 0x42);
    expect(raw[2], 0x31);

    // No readable JSON anywhere in the blob.
    final asText = utf8.decode(raw, allowMalformed: true);
    expect(asText.contains('rootKey'), isFalse,
        reason: 'field names must not be readable');
    expect(asText.contains('peerId'), isFalse);
    expect(asText.contains('ratchet-ORBIT'), isFalse);
  });

  test('store round-trips the original row including byte leaves', () async {
    final rootKey = List<int>.generate(32, (i) => i * 3 & 0xff);
    await keyStore().put('ratchets', {
      'id': 'rt-roundtrip',
      'peerId': 'ORBIT-B2C3D4E5F6A70819',
      'rootKey': Uint8List.fromList(rootKey),
      'skipped': <String, Object?>{},
      'ns': 12,
      'pn': 3,
    });
    final back = await keyStore().get('ratchets', 'rt-roundtrip');
    expect(back, isNotNull);
    expect(back!['peerId'], 'ORBIT-B2C3D4E5F6A70819');
    expect(back['ns'], 12);
    final restoredRoot = back['rootKey'] as Uint8List;
    expect(restoredRoot, orderedEquals(rootKey));
  });

  test('legacy PLAINTEXT rows written before the fix still decode', () async {
    // Simulate an old row by writing pre-fix style: plain encodeRow output.
    // We do it via raw SQL to bypass the store's write path.
    final legacyJson =
        jsonEncode({'id': 'legacy-key', 'peerId': 'X', '__note': 'old'});
    await database.customStatement(
      "INSERT INTO keys (id, data) VALUES (?, ?)",
      ['legacy-key', Uint8List.fromList(utf8.encode(legacyJson))],
    );
    final back = await keyStore().get('keys', 'legacy-key');
    expect(back, isNotNull,
        reason: 'pre-fix rows must survive the encrypted-store upgrade');
    expect(back!['__note'], 'old');
  });

  test('K01 unlock migration reseals legacy plaintext without another write',
      () async {
    final legacyJson =
        jsonEncode({'id': 'legacy-migrate', 'peerId': 'Y', 'secret': 'plain'});
    await database.customStatement(
      'INSERT INTO keys (id, data) VALUES (?, ?)',
      ['legacy-migrate', Uint8List.fromList(utf8.encode(legacyJson))],
    );
    final before = await (database.select(database.keysTable)
          ..where((t) => t.id.equals('legacy-migrate')))
        .getSingle();
    expect(isBlobWrapped(before.data), isFalse);

    final n = await migrateLegacySealedRows();
    expect(n, greaterThanOrEqualTo(1));

    final after = await (database.select(database.keysTable)
          ..where((t) => t.id.equals('legacy-migrate')))
        .getSingle();
    expect(isBlobWrapped(after.data), isTrue);
    expect(after.data[0], 0x4F);
    final back = await keyStore().get('keys', 'legacy-migrate');
    expect(back!['secret'], 'plain');
  });

  test('locked vault → put fails closed and writes nothing', () async {
    clearVaultKek();
    expect(
      () => keyStore().put('keys', {
        'id': 'nokek',
        'privateKey': Uint8List.fromList([1, 2, 3]),
      }),
      throwsStateError,
    );
    final rows = await (database.select(database.keysTable)).get();
    expect(rows, isEmpty, reason: 'failed-closed write must persist nothing');
  });

  test('prekeys table is sealed too', () async {
    await keyStore().put('prekeys', {
      'id': 'pk-1',
      'kind': 'spk', // column allows ≤8 chars
      'used': 0,
      'privateKey': Uint8List.fromList(List<int>.filled(32, 0xAB)),
    });
    final rows = await (database.select(database.prekeysTable)).get();
    expect(rows, hasLength(1));
    expect(rows.first.data[0], 0x4F);
    expect(rows.first.data[1], 0x42);
    expect(rows.first.data[2], 0x31);
  });
}
