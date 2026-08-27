// Minimal key/value abstraction for crypto state that the JS side persists
// to IndexedDB.
//
// The React build uses `src/core/db.js` (an `idb`-wrapped IndexedDB database)
// as the single source of truth for identity keys, prekeys, pins, bundle
// cache, and ratchet snapshots. The Flutter port will eventually replace it
// with Isar / Hive / Drift (see research/05_Storage.md — Phase 9). Until
// then, the crypto modules need *some* storage to compile against, so this
// file defines the contract and ships an in-memory default.
//
// The shape is intentionally small — "table" is a namespace string, every
// record has a stable `id` field, and indexes are plain filters. It's not
// trying to be a real ORM; it only has to satisfy the half-dozen
// `db.get / put / delete / getAll` calls that the JS code makes.

import 'dart:async';

/// Minimal per-table key/value store. Implementations must be safe to call
/// from anywhere in the app; the in-memory default is sync internally but
/// wraps everything in Futures so callers can swap in a real disk-backed
/// impl without changing call sites.
abstract class KeyStore {
  /// Fetch a row by its primary id. Returns null if absent.
  Future<Map<String, Object?>?> get(String table, String id);

  /// Insert or replace a row. The row's `id` field is the primary key — it
  /// is *required* on every put.
  Future<void> put(String table, Map<String, Object?> value);

  /// Delete a row by id. No-op if absent.
  Future<void> delete(String table, String id);

  /// All rows in a table, optionally filtered by an index field value.
  Future<List<Map<String, Object?>>> getAll(
    String table, {
    String? indexField,
    Object? indexValue,
  });

  /// Atomically update [id] if [ifMatches] is true on the current row.
  /// Returns the written row, or null if the row is missing / predicate
  /// failed. Implementations must serialize concurrent CAS so only one
  /// winner observes a successful match (R08).
  Future<Map<String, Object?>?> compareAndUpdate(
    String table,
    String id, {
    required bool Function(Map<String, Object?> row) ifMatches,
    required Map<String, Object?> Function(Map<String, Object?> row) update,
  });
}

/// Process-local fallback for the KeyStore. Good enough for unit tests and
/// the crypto round-trip fixtures. Lost on app restart — real persistence
/// lives in a future Isar/Hive/Drift adapter.
class InMemoryKeyStore implements KeyStore {
  final Map<String, Map<String, Map<String, Object?>>> _tables = {};
  Future<void> _casChain = Future<void>.value();

  Map<String, Map<String, Object?>> _table(String name) =>
      _tables.putIfAbsent(name, () => <String, Map<String, Object?>>{});

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final gate = Completer<void>();
    final prev = _casChain;
    _casChain = gate.future;
    return prev.then((_) => action()).whenComplete(() {
      if (!gate.isCompleted) gate.complete();
    });
  }

  @override
  Future<Map<String, Object?>?> get(String table, String id) async {
    final row = _table(table)[id];
    if (row == null) return null;
    // Return a shallow copy so callers can't mutate stored state by accident.
    return Map<String, Object?>.from(row);
  }

  @override
  Future<void> put(String table, Map<String, Object?> value) async {
    final id = value['id'];
    if (id is! String || id.isEmpty) {
      throw ArgumentError('key_store: put requires a non-empty String id');
    }
    _table(table)[id] = Map<String, Object?>.from(value);
  }

  @override
  Future<void> delete(String table, String id) async {
    _table(table).remove(id);
  }

  @override
  Future<List<Map<String, Object?>>> getAll(
    String table, {
    String? indexField,
    Object? indexValue,
  }) async {
    final rows = _table(table).values;
    if (indexField == null) {
      return rows.map((r) => Map<String, Object?>.from(r)).toList();
    }
    return rows
        .where((r) => r[indexField] == indexValue)
        .map((r) => Map<String, Object?>.from(r))
        .toList();
  }

  @override
  Future<Map<String, Object?>?> compareAndUpdate(
    String table,
    String id, {
    required bool Function(Map<String, Object?> row) ifMatches,
    required Map<String, Object?> Function(Map<String, Object?> row) update,
  }) {
    return _exclusive(() async {
      final current = await get(table, id);
      if (current == null || !ifMatches(current)) return null;
      final next = Map<String, Object?>.from(update(current));
      next['id'] = id;
      await put(table, next);
      return next;
    });
  }
}

// Global singleton. Swap via [setKeyStore] once a persistent backend lands.
KeyStore _instance = InMemoryKeyStore();

KeyStore keyStore() => _instance;

void setKeyStore(KeyStore impl) {
  _instance = impl;
}
