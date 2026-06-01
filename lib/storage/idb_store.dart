// Port of `src/core/idbStore.js`.
//
// Tiny key/value API backed by the `kv` table. Storage for small opaque
// blobs the app wants to survive a restart without going through the
// typed `OrbitsDb` surface — auth tokens, cached server responses, feature
// flag overrides.
//
// Values are bytes; callers that want strings should UTF-8 encode /
// decode themselves (see [idbGetString] / [idbPutString] helpers).

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart';

import 'database.dart';

/// Returns the stored bytes for [key], or `null` if absent.
Future<Uint8List?> idbGet(String key) async {
  final db = orbitsDb();
  final row = await (db.select(db.kvTable)..where((t) => t.key.equals(key)))
      .getSingleOrNull();
  return row?.value;
}

/// Upsert [value] under [key]. Any previous value is replaced.
Future<void> idbSet(String key, List<int> value) async {
  final db = orbitsDb();
  await db.into(db.kvTable).insertOnConflictUpdate(
        KvTableCompanion.insert(
          key: key,
          value: Uint8List.fromList(value),
        ),
      );
}

/// Remove [key]. No-op if absent.
Future<void> idbDel(String key) async {
  final db = orbitsDb();
  await (db.delete(db.kvTable)..where((t) => t.key.equals(key))).go();
}

/// Wipe every kv entry. Used by the full local wipe (audit H4) — the kv table
/// holds the persisted auth token and its HMAC signing key, which must not
/// survive a "reset profile".
Future<void> idbClearAll() async {
  final db = orbitsDb();
  await db.delete(db.kvTable).go();
}

// ─── String convenience ─────────────────────────────────────────────
//
// The JS side stored JWT-style tokens as strings via `store.put(value, key)`
// with no framing. These helpers let the Dart ports keep the same
// ergonomics without asking every caller to utf8.encode.

Future<String?> idbGetString(String key) async {
  final bytes = await idbGet(key);
  if (bytes == null) return null;
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return null;
  }
}

Future<void> idbSetString(String key, String value) =>
    idbSet(key, utf8.encode(value));
