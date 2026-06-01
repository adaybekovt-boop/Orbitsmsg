// Native SQLCipher executor — the live encrypted opener used by `_open()`.
//
// Opens `<appSupportDir>/orbits.sqlite` through Drift's [NativeDatabase] and
// applies `PRAGMA key` (the HKDF-derived hex key) as the very first statement,
// so the whole DB file is encrypted at rest by SQLCipher.
//
// ── Key source ──
// We key off a dedicated 32-byte *device* DB key kept in `flutter_secure_storage`
// (hardware-backed), NOT the post-unlock vault KEK. This is forced by the app's
// own flow: the peerId/identity is shown during onboarding BEFORE the user sets
// a password, so the identity row must be readable before any password-derived
// KEK can exist — i.e. there is no vault KEK available when the DB is first
// opened at bootstrap. A device key is always available, so the DB opens with
// zero unlock friction. (To bind the DB to the password KEK instead, the
// bootstrap would first have to move identity/profile reads out of this DB.)
//
// ── No destructive migration ──
// SQLCipher can't open a pre-existing *plaintext* `orbits.sqlite` with a key.
// To avoid bricking or wiping existing installs, encryption only applies to a
// freshly-created DB: a secure-storage marker records "this DB is encrypted".
// An existing plaintext DB (marker absent, file present) is opened as-is —
// message/peer rows are still vault-encrypted at the row level. Wipe + re-
// onboard to get a fully-encrypted container, or add a `sqlcipher_export`
// migration later.
//
// Requires `sqlcipher_flutter_libs` linked so the loaded sqlite3 understands
// `PRAGMA key`.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'db_key_derivation.dart';

const String _dbKeyStorageKey = 'orbits.db.key.v1';
const String _encMarkerKey = 'orbits.db.encrypted.v1';

QueryExecutor? openCipherExecutor() {
  // Always returns an executor on native; the encrypt-vs-plaintext decision
  // (which needs async secure-storage reads) happens inside the lazy callback.
  return LazyDatabase(() async {
    const store = FlutterSecureStorage();
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}orbits.sqlite');

    String? marker;
    try {
      marker = await store.read(key: _encMarkerKey);
    } catch (_) {
      marker = null;
    }
    // ── Lost-key recovery (audit finding 2) ──
    // If this DB was created encrypted (marker == '1') and the file still
    // exists, but the device key is *definitely* gone (Keystore wipe, data
    // clear, device transfer), the file is permanently unreadable. Silently
    // regenerating a key would just make SQLCipher fail on the first query
    // with no recovery and no signal. Instead move the unreadable file aside
    // and start fresh so the app can boot (the user re-onboards). We rename
    // (not delete) in case the key resurfaces, and ONLY act when the key read
    // SUCCEEDS and is conclusively absent — a transient read error must never
    // be allowed to move a perfectly good encrypted DB.
    if (marker == '1' && file.existsSync()) {
      if (await _dbKeyDefinitelyMissing(store)) {
        try {
          await file.rename('${file.path}.unreadable');
        } catch (_) {
          try {
            await file.delete();
          } catch (_) {}
        }
        try {
          await store.delete(key: _encMarkerKey);
        } catch (_) {}
        marker = null;
      }
    }

    final fileExists = file.existsSync();

    // Encrypt when: this DB was already created encrypted (marker), OR it's a
    // brand-new DB (no marker, no file). A legacy plaintext file stays plain.
    final shouldEncrypt = marker == '1' || (marker == null && !fileExists);

    if (!shouldEncrypt) {
      return NativeDatabase.createInBackground(file);
    }

    final keyMaterial = await _loadOrCreateDbKey(store);
    final hexKey = deriveSqlcipherKeyHex(keyMaterial);

    // Persist the marker the first time we encrypt a fresh DB.
    if (marker != '1') {
      try {
        await store.write(key: _encMarkerKey, value: '1');
      } catch (_) {
        // Non-fatal — worst case we re-evaluate next launch; the key is stable.
      }
    }

    return NativeDatabase.createInBackground(
      file,
      setup: (rawDb) {
        // Must be the first statement on the connection.
        rawDb.execute("PRAGMA key = '$hexKey'");
      },
    );
  });
}

/// Load (or generate-and-store on first run) the 32-byte device DB key.
Future<List<int>> _loadOrCreateDbKey(FlutterSecureStorage store) async {
  try {
    final existing = await store.read(key: _dbKeyStorageKey);
    if (existing != null && existing.isNotEmpty) {
      final bytes = base64Decode(existing);
      if (bytes.length == 32) return bytes;
    }
  } catch (_) {
    // Fall through to regenerate.
  }
  final rng = Random.secure();
  final bytes =
      Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
  final encoded = base64Encode(bytes);
  // Persist + READ BACK (audit finding 1). A write that silently didn't stick
  // would brick the DB on next launch: a different key gets generated →
  // SQLCipher can't open the file → total, unrecoverable, silent data loss.
  // So we fail LOUDLY instead of returning a key we couldn't actually save —
  // better to refuse to create an encrypted DB than to create one we can never
  // reopen. (The bootstrap's try/catch degrades to a recoverable state.)
  try {
    await store.write(key: _dbKeyStorageKey, value: encoded);
    final readBack = await store.read(key: _dbKeyStorageKey);
    if (readBack != encoded) {
      throw StateError('DB key did not persist (read-back mismatch)');
    }
  } catch (e) {
    throw StateError('Cannot persist encrypted-DB key — refusing to create an '
        'unreadable database: $e');
  }
  return bytes;
}

/// True only when the device DB key read SUCCEEDS and the key is conclusively
/// absent or corrupt. A read *exception* returns false (unknown) so a transient
/// secure-storage hiccup can never be mistaken for a lost key.
Future<bool> _dbKeyDefinitelyMissing(FlutterSecureStorage store) async {
  try {
    final existing = await store.read(key: _dbKeyStorageKey);
    if (existing == null || existing.isEmpty) return true;
    final bytes = base64Decode(existing);
    return bytes.length != 32;
  } catch (_) {
    return false;
  }
}
