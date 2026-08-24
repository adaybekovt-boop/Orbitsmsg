// Biometric-gated guardian for the 32-byte vault KEK.
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

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
import 'package:local_auth/local_auth.dart';

const String _kekStorageKey = 'orbits.vault.kek.v1';

/// Android Keystore options for the vault KEK. Exposed so tests can assert
/// the auth binding without a device. Round 2 D.4.
///
/// `AndroidOptions.biometric(enforceBiometrics: true)` maps to
/// `setUserAuthenticationRequired(true)` on the Keystore key. The older
/// comment that v10 had no biometric constructor was **wrong** for 10.3.1.
AndroidOptions androidKekVaultOptions() => const AndroidOptions.biometric(
      enforceBiometrics: true,
      biometricType: AndroidBiometricType.strongBiometricOnly,
      biometricPromptTitle: 'Orbits',
      biometricPromptSubtitle:
          'Подтвердите личность для доступа к ключам профиля',
      biometricPromptNegativeButton: 'Отмена',
    );

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

/// Fail-closed gate: do not read a stored KEK unless biometrics are usable
/// and the upcoming prompt can actually run. `null` means "proceed to prompt".
KekRetrieveStatus? biometricAvailabilityGate(bool usable) =>
    usable ? null : KekRetrieveStatus.cancelled;

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
  SecureKekVault({
    FlutterSecureStorage? storage,
    bool? supportedOverride,
    bool? skipLocalAuthPrompt,
    Future<bool> Function()? biometricUsable,
    Future<String?> Function()? readOverride,
  })  : _storage = storage ?? _defaultStorage(),
        _supportedOverride = supportedOverride,
        _skipLocalAuthPrompt = skipLocalAuthPrompt ?? _defaultSkipLocalAuth(),
        _biometricUsable = biometricUsable,
        _readOverride = readOverride;

  final FlutterSecureStorage _storage;
  final bool? _supportedOverride;
  final bool _skipLocalAuthPrompt;
  final Future<bool> Function()? _biometricUsable;
  final Future<String?> Function()? _readOverride;

  static bool _defaultSkipLocalAuth() {
    try {
      return !kIsWeb && Platform.isAndroid;
    } on UnsupportedError {
      return false;
    }
  }

  /// Probe for hardware-backed biometric support. Desktop / web always
  /// return false; mobile returns true when the platform plugin is loaded
  /// and the secure storage backend is available.
  /// Platform capability (no constructor). Used by [AutoUnlockService].
  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isIOS || Platform.isAndroid;
    } on UnsupportedError {
      return false;
    }
  }

  bool get _effectiveSupported => _supportedOverride ?? isSupported;

  /// Persist a freshly-derived 32-byte KEK under biometric protection.
  /// Overwrites any previous value — call this right after successful
  /// master-password validation.
  Future<void> storeKek(List<int> kekBytes) async {
    if (kekBytes.length != 32) {
      throw ArgumentError('SecureKekVault: KEK must be exactly 32 bytes');
    }
    if (!_effectiveSupported) {
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
    if (!_effectiveSupported) {
      return const KekRetrieveResult(status: KekRetrieveStatus.unsupported);
    }
    // iOS: local_auth still gates the read (no accessControlFlags wired).
    // Android: Keystore user-authentication on [androidKekVaultOptions]
    // is the binding; a second local_auth sheet is not that binding.
    final gate = await _gateBiometric();
    if (gate != null) {
      return KekRetrieveResult(status: gate);
    }
    try {
      final encoded = _readOverride != null
          ? await _readOverride!()
          : await _storage.read(
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

  Future<bool> _probeBiometricUsable() async {
    if (_biometricUsable != null) return _biometricUsable!();
    try {
      final auth = LocalAuthentication();
      return await auth.isDeviceSupported() && await auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  /// Prompt the system biometric (Face ID / Touch ID / fingerprint) before a
  /// KEK read. Returns `null` to proceed to the Keystore/Keychain read, or a
  /// terminal [KekRetrieveStatus] the caller should return immediately.
  Future<KekRetrieveStatus?> _gateBiometric() async {
    // Android (and tests that simulate it): Keystore user-auth on
    // [androidKekVaultOptions] is the binding. A local_auth *success*
    // is never enough to return the KEK. A local_auth *unavailable*
    // result is enough to refuse the read — otherwise a no-op plugin
    // would hand the ciphertext back with no prompt.
    if (_skipLocalAuthPrompt) {
      final usable = await _probeBiometricUsable();
      return biometricAvailabilityGate(usable);
    }
    final available = await _probeBiometricUsable();
    // Fail closed: a stored KEK is never returned without a successful
    // biometric prompt. Missing hardware/enrollment → password path.
    if (!available) return biometricAvailabilityGate(false);

    try {
      final auth = LocalAuthentication();
      final ok = await auth.authenticate(
        localizedReason: 'Подтвердите личность для доступа к ключам профиля',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
      return ok ? null : KekRetrieveStatus.cancelled;
    } on PlatformException catch (e) {
      if (e.code == auth_error.lockedOut ||
          e.code == auth_error.permanentlyLockedOut) {
        return KekRetrieveStatus.lockedOut;
      }
      if (e.code == auth_error.notAvailable ||
          e.code == auth_error.notEnrolled ||
          e.code == auth_error.passcodeNotSet) {
        // Sensor disappeared between the probe and the prompt — fail closed.
        return KekRetrieveStatus.cancelled;
      }
      return KekRetrieveStatus.cancelled;
    } catch (_) {
      return KekRetrieveStatus.cancelled;
    }
  }

  /// Hard-delete the stored KEK. Called on logout, password rotation, and
  /// after a [KekRetrieveStatus.biometricInvalidated] event.
  Future<void> deleteKek() async {
    if (!_effectiveSupported) return;
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
    if (!_effectiveSupported) return false;
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

  IOSOptions _iosOptions() => const IOSOptions(
        // Blocks iCloud backup + restore-to-another-device.
        accessibility: KeychainAccessibility.unlocked_this_device,
      );

  AndroidOptions _androidOptions() => androidKekVaultOptions();

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
