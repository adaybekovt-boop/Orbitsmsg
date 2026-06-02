// Biometric auto-unlock (honest "remember login" replacement).
//
// Persists the 32-byte vault KEK behind the OS biometric-gated keystore
// (Android Keystore / iOS Keychain) via [SecureKekVault], so the app can
// unlock on launch with Face ID / fingerprint INSTEAD OF re-deriving from the
// password. This is NOT "remember password": the password is never stored, and
// the KEK lives only in the hardware-backed keystore, never in SharedPreferences.
//
// Hard platform gate: secure auto-unlock requires a hardware biometric keystore,
// which exists only on Android/iOS. On Windows (the desktop target), web,
// macOS and Linux this is reported UNSUPPORTED — the UI must then show a clear
// disabled state and the app always unlocks by password. We never fall back to
// storing the KEK in plaintext.
//
// Web-safety: the real implementation imports `dart:io` (via SecureKekVault), so
// it lives behind a conditional import. The web build gets the stub, keeping
// `flutter build web` working even though auth_notifier (in the web graph)
// depends on this file.

import 'dart:typed_data';

import 'auto_unlock_service_io.dart'
    if (dart.library.html) 'auto_unlock_service_stub.dart' as impl;

/// SharedPreferences flag: is biometric auto-unlock turned on by the user.
/// Replaces the old write-only `orbits_auto_login` flag (which was never read).
const String kBiometricUnlockPrefKey = 'orbits_biometric_unlock_v1';

/// Outcome of an auto-unlock attempt at startup. Only [ok] yields KEK bytes;
/// every other value means "fall back to the password screen".
enum AutoUnlockStatus {
  /// KEK retrieved from the secure keystore; proceed to unlock.
  ok,

  /// Feature off, nothing stored, or platform unsupported — silently use password.
  unavailable,

  /// User cancelled / failed the biometric prompt — use password this time.
  cancelled,

  /// Stored KEK was invalidated (new biometrics enrolled, etc.); the stale
  /// entry has been cleared. Use password; the user can re-enable afterwards.
  invalidated,

  /// Unexpected error; use password.
  error,
}

class AutoUnlockResult {
  const AutoUnlockResult(this.status, {this.kek});

  final AutoUnlockStatus status;
  final Uint8List? kek;

  bool get ok => status == AutoUnlockStatus.ok && kek != null;
}

/// Persists/retrieves the vault KEK under OS biometric protection.
abstract class AutoUnlockService {
  /// Whether this platform can do secure biometric auto-unlock at all.
  /// False on Windows / web / macOS / Linux.
  bool get isSupported;

  /// User toggle state (SharedPreferences). Meaningful only when [isSupported].
  Future<bool> isEnabled();

  /// Is a KEK currently persisted in the secure keystore (no biometric prompt).
  Future<bool> hasStoredKek();

  /// Attempt to retrieve the stored KEK (triggers the biometric prompt).
  Future<AutoUnlockResult> retrieve();

  /// Turn the feature ON: store [kekBytes] behind the biometric gate and set the
  /// flag. Returns true on success. No-op + false when unsupported or the vault
  /// is locked (kekBytes null/empty).
  Future<bool> enable(Uint8List? kekBytes);

  /// Turn the feature OFF: delete the stored KEK and clear the flag.
  Future<void> disable();

  /// Re-store the current KEK if the feature is enabled (called after a manual
  /// password unlock so the keystore copy stays fresh). No-op otherwise.
  Future<void> refresh(Uint8List? kekBytes);

  /// Full clear on logout / wipe: delete the stored KEK and clear the flag.
  Future<void> clear();
}

/// The platform-appropriate implementation (real on mobile, stub on web).
AutoUnlockService createAutoUnlockService() => impl.createAutoUnlockService();
