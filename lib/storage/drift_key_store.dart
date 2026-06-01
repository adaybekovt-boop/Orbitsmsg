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

  @override
  Future<Map<String, Object?>?> get(String table, String id) async {
    switch (table) {
      case 'keys':
        final row = await (_db.select(_db.keysTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        return row == null ? null : decodeRow(row.data);
      case 'prekeys':
        final row = await (_db.select(_db.prekeysTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        return row == null ? null : decodeRow(row.data);
      case 'ratchets':
        final row = await (_db.select(_db.ratchetsTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        return row == null ? null : decodeRow(row.data);
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
    final data = encodeRow(value);

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
        return _filter(
            rows.map((r) => decodeRow(r.data)), indexField, indexValue);
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
        return _filter(rows.map((r) => decodeRow(r.data)), indexField,
            indexValue);
      case 'ratchets':
        final query = _db.select(_db.ratchetsTable);
        if (indexField == 'peerId' && indexValue is String) {
          query.where((t) => t.peerId.equals(indexValue));
        }
        final rows = await query.get();
        return _filter(rows.map((r) => decodeRow(r.data)), indexField,
            indexValue);
      default:
        throw ArgumentError(
            'DriftKeyStore: unsupported table "$table" (use storage/db.dart)');
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
