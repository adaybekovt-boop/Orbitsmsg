// Drift-backed implementation of [KeyStore] from `lib/core/key_store.dart`.
//
// Scope: the three tables the crypto modules write to.
//
//   'keys'      → KeysTable      (identity, peer pins, cached bundles)
//   'prekeys'   → PrekeysTable   (indexed by kind / used)
//   'ratchets'  → RatchetsTable  (indexed by peerId)
//
// High-level domain data (peers, messages, avatars, stickers, blobs) is
// handled by `lib/storage/db.dart` via typed methods — don't reach for it
// through this generic KeyStore.
//
// Unknown table names throw — surfaces typos at the call site instead of
// silently losing writes to a new auto-created table.

import 'package:drift/drift.dart';

import '../core/key_store.dart';
import '../core/vault_kek.dart';
import 'database.dart';
import 'row_codec.dart';

/// Install the Drift store as the process-wide [KeyStore]. Call once on
/// app start (after any platform init) and before touching the crypto
/// modules. Tests can swap in [InMemoryKeyStore] by calling [setKeyStore]
/// directly.
void installDriftKeyStore({OrbitsDatabase? database}) {
  setKeyStore(DriftKeyStore(database ?? orbitsDb()));
}

class DriftKeyStore implements KeyStore {
  DriftKeyStore(this._db);

  final OrbitsDatabase _db;

  /// Storage-level encryption (audit Round 5 B.2): EVERY row this store
  /// writes is sealed under the vault KEK with the synchronous OB1 AES-GCM
  /// frame — the same primitive db.dart uses for message/peer content.
  ///
  /// This moves secrecy from caller discipline ("remember to wrapSecret each
  /// field") to a property of the store itself: a raw dump of keys/prekeys/
  /// ratchets yields ciphertext without the KEK. Callers may still wrap
  /// individual fields (double-wrapping is harmless).
  ///
  /// Reads tolerate legacy plaintext rows (pre-fix data) via the OB1 magic
  /// check inside [unwrapBlobSync]. Unlock runs [resealLegacyPlaintext]
  /// (K01) so leftover plaintext is sealed immediately, not only on the
  /// next organic write.
  ///
  /// Locked vault → [wrapBlobSync]/[unwrapBlobSync] throw [StateError]:
  /// writes fail closed; framed reads fail closed too (legacy plaintext
  /// still passes through, matching db.dart semantics).

  @override
  Future<Map<String, Object?>?> get(String table, String id) async {
    switch (table) {
      case 'keys':
        final row = await (_db.select(_db.keysTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        return row == null ? null : decodeRow(unwrapBlobSync(row.data));
      case 'prekeys':
        final row = await (_db.select(_db.prekeysTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        return row == null ? null : decodeRow(unwrapBlobSync(row.data));
      case 'ratchets':
        final row = await (_db.select(_db.ratchetsTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        return row == null ? null : decodeRow(unwrapBlobSync(row.data));
      default:
        throw ArgumentError(
            'DriftKeyStore: unsupported table "$table" (use storage/db.dart '
            'for peers/messages/avatars/stickers/blobs)');
    }
  }

  @override
  Future<void> put(String table, Map<String, Object?> value) async {
    final id = value['id'];
    if (id is! String || id.isEmpty) {
      throw ArgumentError('DriftKeyStore: put requires a non-empty String id');
    }
    final data = wrapBlobSync(encodeRow(value));

    switch (table) {
      case 'keys':
        await _db.into(_db.keysTable).insertOnConflictUpdate(
              KeysTableCompanion.insert(id: id, data: data),
            );
        break;
      case 'prekeys':
        final kind = (value['kind'] as String?) ?? '';
        final used = (value['used'] as num?)?.toInt() ?? 0;
        await _db.into(_db.prekeysTable).insertOnConflictUpdate(
              PrekeysTableCompanion.insert(
                id: id,
                kind: kind,
                used: Value(used),
                data: data,
              ),
            );
        break;
      case 'ratchets':
        final peerId = (value['peerId'] as String?) ?? '';
        await _db.into(_db.ratchetsTable).insertOnConflictUpdate(
              RatchetsTableCompanion.insert(
                id: id,
                peerId: peerId,
                data: data,
              ),
            );
        break;
      default:
        throw ArgumentError(
            'DriftKeyStore: unsupported table "$table" (use storage/db.dart '
            'for peers/messages/avatars/stickers/blobs)');
    }
  }

  @override
  Future<void> delete(String table, String id) async {
    switch (table) {
      case 'keys':
        await (_db.delete(_db.keysTable)..where((t) => t.id.equals(id))).go();
        break;
      case 'prekeys':
        await (_db.delete(_db.prekeysTable)..where((t) => t.id.equals(id)))
            .go();
        break;
      case 'ratchets':
        await (_db.delete(_db.ratchetsTable)..where((t) => t.id.equals(id)))
            .go();
        break;
      default:
        throw ArgumentError(
            'DriftKeyStore: unsupported table "$table" (use storage/db.dart)');
    }
  }

  @override
  Future<List<Map<String, Object?>>> getAll(
    String table, {
    String? indexField,
    Object? indexValue,
  }) async {
    switch (table) {
      case 'keys':
        final rows = await _db.select(_db.keysTable).get();
        return _filter(rows.map((r) => decodeRow(unwrapBlobSync(r.data))),
            indexField, indexValue);
      case 'prekeys':
        final query = _db.select(_db.prekeysTable);
        // Promote the common `kind=` / `used=` filters to SQL — otherwise
        // we degrade to a full-table scan + Dart-side filter.
        if (indexField == 'kind' && indexValue is String) {
          query.where((t) => t.kind.equals(indexValue));
        } else if (indexField == 'used' && indexValue is num) {
          query.where((t) => t.used.equals(indexValue.toInt()));
        }
        final rows = await query.get();
        return _filter(rows.map((r) => decodeRow(unwrapBlobSync(r.data))),
            indexField, indexValue);
      case 'ratchets':
        final query = _db.select(_db.ratchetsTable);
        if (indexField == 'peerId' && indexValue is String) {
          query.where((t) => t.peerId.equals(indexValue));
        }
        final rows = await query.get();
        return _filter(rows.map((r) => decodeRow(unwrapBlobSync(r.data))),
            indexField, indexValue);
      default:
        throw ArgumentError(
            'DriftKeyStore: unsupported table "$table" (use storage/db.dart)');
    }
  }

  @override
  Future<Map<String, Object?>?> compareAndUpdate(
    String table,
    String id, {
    required bool Function(Map<String, Object?> row) ifMatches,
    required Map<String, Object?> Function(Map<String, Object?> row) update,
  }) {
    return _db.transaction(() async {
      // For prekeys, CAS the indexed `used` column first so a concurrent
      // transaction cannot also observe used=0 (R08).
      if (table == 'prekeys') {
        final claimed = await _db.customUpdate(
          'UPDATE prekeys SET used = 1 WHERE id = ? AND used = 0',
          variables: [Variable<String>(id)],
          updates: {_db.prekeysTable},
          updateKind: UpdateKind.update,
        );
        if (claimed != 1) return null;
      }
      final current = await get(table, id);
      if (current == null) return null;
      // The SQL claim already flipped used=1; evaluate the caller's
      // predicate against the pre-claim snapshot.
      final snapshot = table == 'prekeys'
          ? (Map<String, Object?>.from(current)..['used'] = 0)
          : current;
      if (!ifMatches(snapshot)) return null;
      final next = Map<String, Object?>.from(update(snapshot));
      next['id'] = id;
      await put(table, next);
      return next;
    });
  }

  /// Versioned unlock migration (K01): re-seal every legacy plaintext
  /// keys/prekeys/ratchets row immediately, without waiting for the next
  /// organic write.
  Future<int> resealLegacyPlaintext() async {
    var n = 0;
    n += await _reseal('keys');
    n += await _reseal('prekeys');
    n += await _reseal('ratchets');
    return n;
  }

  Future<int> _reseal(String table) async {
    final rows = await getAll(table);
    var n = 0;
    for (final row in rows) {
      final id = row['id'];
      if (id is! String || id.isEmpty) continue;
      final raw = await _rawData(table, id);
      if (raw == null || isBlobWrapped(raw)) continue;
      await put(table, row);
      n++;
    }
    return n;
  }

  Future<Uint8List?> _rawData(String table, String id) async {
    switch (table) {
      case 'keys':
        final row = await (_db.select(_db.keysTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        return row?.data;
      case 'prekeys':
        final row = await (_db.select(_db.prekeysTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        return row?.data;
      case 'ratchets':
        final row = await (_db.select(_db.ratchetsTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        return row?.data;
      default:
        return null;
    }
  }

  /// Second-pass filter for indexes we didn't promote to SQL. Matches
  /// `InMemoryKeyStore` semantics (`==` against the decoded Dart value).
  List<Map<String, Object?>> _filter(
    Iterable<Map<String, Object?>> rows,
    String? field,
    Object? value,
  ) {
    if (field == null) return rows.toList();
    return rows.where((r) => r[field] == value).toList();
  }
}
