// Guardian for the 32-byte vault KEK.
//
// NOTE: the per-read biometric prompt described below is NOT yet wired (see
// the platform-option builders near the bottom). As implemented, the KEK is
// stored hardware-backed (iOS keychain / Android Keystore via
// EncryptedSharedPreferences) and gated only by device unlock — there is no
// Face ID / Touch ID prompt on retrieve. Wiring that needs the `local_auth`
// package plus iOS/Android platform config; until then this class is also not
// referenced by the auth flow. Treat the "triggers Face ID" wording below as
// the intended end state, not current behaviour.
//
// Layered design, per research/07_Secure_device_storage.md:
//
//   password → scrypt dk (32 bytes)         ← derived once, never stored
//       ↓
//   setVaultKek(dk)                          ← [vault_kek.dart] keeps dk in RAM
//       ↓
//   SecureKekVault.storeKek(dk)              ← this file: hands dk to the OS
//                                              keychain / keystore behind a
//                                              biometric gate. OS wraps it
//                                              with a hardware-backed key.
//
// On relaunch:
//
//   SecureKekVault.retrieveKek()             ← triggers Face ID / Touch ID /
//                                              fingerprint prompt. OS
//                                              unwraps and returns dk.
//   setVaultKek(dk)                          ← session is unlocked again
//                                              without typing the password.
//
// If biometrics change (new face enrolled, fingerprint added) the OS
// invalidates the wrapping key — [retrieveKek] returns
// [KekRetrieveStatus.biometricInvalidated] and the UI falls back to the
// master-password screen. Same for cancellation and hardware lockouts.
//
// Important platform notes baked into the config:
//   iOS   — KeychainAccessibility.unlocked_this_device blocks iCloud backup
//           and restore-to-other-device leaks; accessControlFlags bind the
//           ciphertext to the current biometric set (Face ID / Touch ID).
//   Android — enforceBiometrics: true maps to
//             setUserAuthenticationRequired(true) on the Keystore key; any
//             biometric enrollment change invalidates it
//             (KeyPermanentlyInvalidatedException). `dataExtractionRules.xml`
//             in the Android manifest keeps the shared-prefs file out of
//             cloud / device-transfer backups — required by the package
//             (see research/07 §3).

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const String _kekStorageKey = 'orbits.vault.kek.v1';

/// Outcome of a [SecureKekVault.retrieveKek] call. The caller dispatches on
/// this enum — `ok` is the only path that yields bytes, everything else
/// means "drop to master-password entry".
enum KekRetrieveStatus {
  /// KEK retrieved; `bytes` is populated.
  ok,

  /// Nothing stored yet (first launch, or vault was wiped).
  notStored,

  /// Stored KEK exists but the wrapping key was invalidated — new
  /// biometrics enrolled, passcode removed, etc. The stale entry has
  /// already been deleted; the caller should prompt for the password.
  biometricInvalidated,

  /// User tapped "Cancel" on the system prompt.
  cancelled,

  /// Too many failed attempts — datchик временно / перманентно заблокирован.
  lockedOut,

  /// Platform does not support hardware-backed biometric storage (desktop,
  /// web, Android < 6, etc.). Caller should not attempt to persist the KEK.
  unsupported,

  /// Catch-all for unexpected PlatformException codes. `message` carries
  /// the OS error so it can be logged.
  error,
}

/// Value-object returned from [SecureKekVault.retrieveKek]. Exactly one
/// shape is meaningful per status: [bytes] is non-null only when
/// [status] == [KekRetrieveStatus.ok].
class KekRetrieveResult {
  const KekRetrieveResult({required this.status, this.bytes, this.message});

  final KekRetrieveStatus status;
  final Uint8List? bytes;
  final String? message;

  bool get isOk => status == KekRetrieveStatus.ok && bytes != null;
}

/// Secure KEK persistence. Instances are cheap to construct — the
/// underlying `FlutterSecureStorage` handle holds no state.
class SecureKekVault {
  SecureKekVault({FlutterSecureStorage? storage})
      : _storage = storage ?? _defaultStorage();

  final FlutterSecureStorage _storage;

  /// Probe for hardware-backed biometric support. Desktop / web always
  /// return false; mobile returns true when the platform plugin is loaded
  /// and the secure storage backend is available.
  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isIOS || Platform.isAndroid;
    } on UnsupportedError {
      return false;
    }
  }

  /// Persist a freshly-derived 32-byte KEK under biometric protection.
  /// Overwrites any previous value — call this right after successful
  /// master-password validation.
  Future<void> storeKek(List<int> kekBytes) async {
    if (kekBytes.length != 32) {
      throw ArgumentError('SecureKekVault: KEK must be exactly 32 bytes');
    }
    if (!isSupported) {
      throw StateError(
          'SecureKekVault: hardware-backed storage unavailable on this platform');
    }
    final encoded = base64Encode(kekBytes);
    await _storage.write(
      key: _kekStorageKey,
      value: encoded,
      iOptions: _iosOptions(),
      aOptions: _androidOptions(),
    );
  }

  /// Attempt to fetch the stored KEK. Triggers a system biometric prompt
  /// the first time in a session (and every time on Android once the key
  /// requires re-auth). Callers must dispatch on the returned status.
  Future<KekRetrieveResult> retrieveKek() async {
    if (!isSupported) {
      return const KekRetrieveResult(status: KekRetrieveStatus.unsupported);
    }
    try {
      final encoded = await _storage.read(
        key: _kekStorageKey,
        iOptions: _iosOptions(),
        aOptions: _androidOptions(),
      );
      if (encoded == null || encoded.isEmpty) {
        return const KekRetrieveResult(status: KekRetrieveStatus.notStored);
      }
      final bytes = base64Decode(encoded);
      if (bytes.length != 32) {
        // Corrupt entry — wipe and pretend it never existed.
        await deleteKek();
        return const KekRetrieveResult(status: KekRetrieveStatus.notStored);
      }
      return KekRetrieveResult(
        status: KekRetrieveStatus.ok,
        bytes: Uint8List.fromList(bytes),
      );
    } on PlatformException catch (e) {
      return _mapPlatformException(e);
    } catch (e) {
      return KekRetrieveResult(
        status: KekRetrieveStatus.error,
        message: e.toString(),
      );
    }
  }

  /// Hard-delete the stored KEK. Called on logout, password rotation, and
  /// after a [KekRetrieveStatus.biometricInvalidated] event.
  Future<void> deleteKek() async {
    if (!isSupported) return;
    try {
      await _storage.delete(
        key: _kekStorageKey,
        iOptions: _iosOptions(),
        aOptions: _androidOptions(),
      );
    } catch (_) {
      // Best-effort — a delete failure on an already-gone key is fine.
    }
  }

  /// Fast yes/no check without a biometric prompt. Uses the plugin's
  /// `containsKey`, which reads only metadata, so no user interaction.
  Future<bool> hasStoredKek() async {
    if (!isSupported) return false;
    try {
      return await _storage.containsKey(
        key: _kekStorageKey,
        iOptions: _iosOptions(),
        aOptions: _androidOptions(),
      );
    } catch (_) {
      return false;
    }
  }

  // ─── Platform option builders ────────────────────────────────────

  // flutter_secure_storage 10.0.0-beta.4 ships a slimmed-down options
  // surface compared to what the original draft of this file targeted:
  //   • IOSOptions has no typed `accessControlFlags` list — the v10 API
  //     exposes `accessControlSettings` as a raw String? that maps onto
  //     SecAccessControlCreateFlags at the platform layer. There's no
  //     enum helper yet, so we leave it null and rely on
  //     `accessibility` alone for now.
  //   • AndroidOptions has no `.biometric()` named constructor, no
  //     `enforceBiometrics`, no `biometricPromptTitle/Subtitle`. The
  //     biometric prompt API was deferred out of the v10 beta and isn't
  //     reachable through Options.
  //
  // Net effect: data is still hardware-backed (iOS keychain + Android
  // Keystore via EncryptedSharedPreferences), but the per-read biometric
  // gate has to be reintroduced via `local_auth` once we wire it in. Tracked
  // as a follow-up — for the web/desktop-first launch this code path
  // returns `unsupported` early anyway (see [isSupported]).
  IOSOptions _iosOptions() => const IOSOptions(
        // Blocks iCloud backup + restore-to-another-device.
        accessibility: KeychainAccessibility.unlocked_this_device,
      );

  AndroidOptions _androidOptions() => const AndroidOptions();

  KekRetrieveResult _mapPlatformException(PlatformException e) {
    final msg = e.message ?? '';
    final code = e.code;

    // Android — `KeyPermanentlyInvalidatedException` surfaces through
    // BadPaddingException / AEADBadTagException on the native side.
    if (msg.contains('KeyPermanentlyInvalidatedException') ||
        msg.contains('BadPaddingException') ||
        msg.contains('AEADBadTagException')) {
      // Stale ciphertext is dead weight — wipe it.
      unawaited(deleteKek());
      return const KekRetrieveResult(
        status: KekRetrieveStatus.biometricInvalidated,
      );
    }

    // iOS — errSecAuthFailed also shows up when the biometric set changed.
    if (code == 'errSecAuthFailed') {
      unawaited(deleteKek());
      return const KekRetrieveResult(
        status: KekRetrieveStatus.biometricInvalidated,
      );
    }

    if (code == 'errSecUserCanceled' ||
        code == 'AuthError' ||
        msg.contains('User canceled') ||
        msg.contains('cancelled') ||
        msg.contains('canceled')) {
      return const KekRetrieveResult(status: KekRetrieveStatus.cancelled);
    }

    if (msg.contains('Biometric prompt locked out') ||
        msg.contains('LockedOut') ||
        msg.contains('lockedOut')) {
      return const KekRetrieveResult(status: KekRetrieveStatus.lockedOut);
    }

    return KekRetrieveResult(
      status: KekRetrieveStatus.error,
      message: '$code: $msg',
    );
  }

  static FlutterSecureStorage _defaultStorage() {
    return const FlutterSecureStorage();
  }
}
