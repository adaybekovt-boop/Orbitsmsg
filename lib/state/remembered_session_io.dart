// Native "Remember me": persist the 32-byte vault KEK in OS-backed secure
// storage so a desktop launch can auto-unlock without re-typing the password.
//
// WHY this exists (and why it's desktop-first):
//   • A desktop app's process dies on quit, dropping the in-RAM vault KEK — so
//     without this every launch hits the password screen. There is no hardware
//     biometric keystore on desktop (`SecureKekVault` is iOS/Android-only), so
//     "remember me" is the honest desktop equivalent of mobile's biometric
//     auto-unlock.
//   • Storage is OS-backed and tied to the OS user account, NEVER plaintext on
//     disk: DPAPI on Windows, Keychain on macOS, libsecret on Linux — all via
//     flutter_secure_storage. Clearing the OS account / logging out of the app
//     forgets it (expected).
//   • We store ONLY the 32-byte KEK (base64), never the password. On bootstrap
//     the KEK is validated against the stored scrypt record (`kekMatchesRecord`)
//     before it ever unlocks the vault, so a stale/corrupt value is rejected,
//     not trusted.
//
// PLATFORM: mobile (Android/iOS) returns `isRememberSupported() == false` — it
// uses the biometric-gated `SecureKekVault` instead, which is strictly stronger
// than an ungated "stay signed in". Web uses `remembered_session_web.dart`
// (a non-extractable WebCrypto key). This file is the default (non-web) branch
// of the conditional import, so it only ever compiles for the `dart:io` targets.

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Storage key for the remembered KEK. `v1` so a format change can invalidate
/// cleanly. Distinct from `SecureKekVault`'s key — a different mechanism.
const String _kStorageKey = 'orbits.remember.kek.v1';

/// Minimal secret-store seam so tests can swap the real OS-backed storage for an
/// in-memory fake (the platform plugin isn't available under `flutter test`).
abstract class RememberedKekStore {
  /// Whether this backend is usable on this device right now.
  Future<bool> available();

  /// Read the stored value (base64 KEK), or null when absent.
  Future<String?> read();

  /// Persist [value] (base64 KEK).
  Future<void> write(String value);

  /// Forget any stored value.
  Future<void> delete();
}

/// Default backend: `flutter_secure_storage` over the OS secret store. Desktop
/// only — mobile defers to the biometric `SecureKekVault`.
class _SecureStorageKekStore implements RememberedKekStore {
  const _SecureStorageKekStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<bool> available() async {
    if (kIsWeb) return false;
    // Desktop only: mobile uses the biometric vault, which is stronger.
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return false;
    }
    try {
      // A read of a (possibly absent) key returns null on a healthy backend and
      // throws when the backend is missing (e.g. no libsecret on Linux). So a
      // call that returns at all — null or not — means the store works.
      await _storage.read(key: _kStorageKey);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> read() => _storage.read(key: _kStorageKey);

  @override
  Future<void> write(String value) =>
      _storage.write(key: _kStorageKey, value: value);

  @override
  Future<void> delete() => _storage.delete(key: _kStorageKey);
}

RememberedKekStore _store = const _SecureStorageKekStore();

/// Test seam: swap the backing store (pass null to restore the OS-backed one).
@visibleForTesting
set debugRememberedKekStore(RememberedKekStore? store) {
  _store = store ?? const _SecureStorageKekStore();
}

/// Whether secure remembered-session storage is available on this device.
Future<bool> isRememberSupported() async {
  try {
    return await _store.available();
  } catch (_) {
    return false;
  }
}

/// Persist the 32-byte vault KEK (base64) for auto-unlock. Stores ONLY the KEK,
/// never the password. Best-effort: a failure here must never break login.
Future<void> persistKek(List<int> kek) async {
  try {
    if (kek.length != 32) return; // only ever persist a full 32-byte KEK
    if (!await _store.available()) return;
    await _store.write(base64Encode(kek));
  } catch (_) {
    // Best-effort — failing to remember must never break a successful login.
  }
}

/// Load a previously remembered KEK, or null. A malformed or wrong-length value
/// is forgotten and treated as absent so it can't wedge auto-unlock.
Future<Uint8List?> loadKek() async {
  try {
    if (!await _store.available()) return null;
    final encoded = await _store.read();
    if (encoded == null || encoded.isEmpty) return null;
    Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } catch (_) {
      await _store.delete(); // malformed → forget it
      return null;
    }
    if (bytes.length != 32) {
      await _store.delete(); // wrong length → forget it
      return null;
    }
    return Uint8List.fromList(bytes);
  } catch (_) {
    return null;
  }
}

/// Forget any remembered KEK (logout / "remember me" unchecked / stale value).
Future<void> clearRememberedKek() async {
  try {
    await _store.delete();
  } catch (_) {}
}
