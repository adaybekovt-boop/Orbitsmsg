// Port of src/context/AuthContext.jsx — Riverpod StateNotifier replacing the
// React provider. Keeps the same four-state machine (loading/guest/locked/
// authed) and the same four actions the UI calls (completeOnboarding, unlock,
// logout, wipeLocal).
//
// Architectural choices the React build doesn't have to worry about:
//   • SharedPreferences is async → the notifier starts in `loading` and moves
//     to one of the terminal states once `_bootstrap()` finishes. The React
//     version could read localStorage synchronously in a `useEffect`, but we
//     can't afford to block the UI thread.
//   • Scrypt blocks for ~400–800 ms, but `scrypt_kdf.dart` now runs that
//     pure-Dart derivation in a background isolate (`Isolate.run`), so the UI
//     thread no longer hitches during onboarding/unlock (audit L10). The
//     HMAC-SHA256 verifier still runs inline — it's microseconds, not the
//     bottleneck. Callers still see `busy=true` via the action Future.
//   • `reserveName` / registry.js is skipped: that was a browser-era concern
//     about multiple profiles sharing the same origin. On mobile the device
//     is the profile.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth_validation.dart';
import '../core/identity.dart';
import '../core/identity_key.dart' as identity_key;
import '../core/scrypt_kdf.dart';
import '../core/vault_kek.dart';
import '../storage/db.dart' as db;
import '../storage/secure_profile_store.dart';
import 'auto_unlock_service.dart';
import 'remembered_session_stub.dart'
    if (dart.library.html) 'remembered_session_web.dart' as remembered;

// ─────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────

/// One-of-four auth state. Sealed so a `switch` is exhaustive at compile time.
sealed class AuthState {
  const AuthState();
}

class AuthLoading extends AuthState {
  const AuthLoading();
}

/// First-run — no profile on disk. UI: onboarding wizard.
class AuthGuest extends AuthState {
  const AuthGuest();
}

/// Profile exists but vault is locked. UI: single password field.
class AuthLocked extends AuthState {
  const AuthLocked(this.profile);
  final LocalProfile profile;
}

/// Vault is unlocked; ratchets and chats can run.
class AuthAuthed extends AuthState {
  const AuthAuthed(this.user);
  final AuthedUser user;
}

/// What the UI gets when authed. Mirrors the object React `setUser` held.
class AuthedUser {
  const AuthedUser({
    required this.peerId,
    required this.displayName,
    required this.bio,
    required this.avatarDataUrl,
  });
  final String peerId;
  final String displayName;
  final String bio;
  final String? avatarDataUrl;

  AuthedUser copyWith({
    String? displayName,
    String? bio,
    String? avatarDataUrl,
  }) =>
      AuthedUser(
        peerId: peerId,
        displayName: displayName ?? this.displayName,
        bio: bio ?? this.bio,
        avatarDataUrl: avatarDataUrl ?? this.avatarDataUrl,
      );
}

/// Thrown by [AuthNotifier] actions so the UI can match on a stable code
/// instead of parsing messages. The `message` is Russian, ready to display.
class AuthException implements Exception {
  const AuthException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => 'AuthException($code): $message';
}

// ─────────────────────────────────────────────────────────────
// Notifier
// ─────────────────────────────────────────────────────────────

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier({AutoUnlockService? autoUnlock})
      : _autoUnlock = autoUnlock ?? createAutoUnlockService(),
        super(const AuthLoading()) {
    // Fire-and-forget — the state transitions to guest/locked/authed when
    // `_bootstrap()` resolves. AuthGate shows a splash while we're loading.
    _bootstrap();
  }

  /// Biometric auto-unlock (mobile only). Stores the KEK behind the OS
  /// biometric keystore so launch can skip the password. Unsupported (and a
  /// no-op) on Windows / web / desktop.
  final AutoUnlockService _autoUnlock;

  bool get autoUnlockSupported => _autoUnlock.isSupported;

  Future<void> _bootstrap() async {
    try {
      // Always ensure an identity row exists, even for guests. The React
      // onboarding shows the peerId on step 3 BEFORE the user sets a
      // password, so it has to be there from the start.
      final identity = await getOrCreateIdentity();
      final profile = await loadLocalProfile();

      if (profile == null || profile.displayName.trim().isEmpty) {
        state = const AuthGuest();
        return;
      }

      // Keep the identity's displayName in sync with whatever the profile
      // says — handy once profile editing lands.
      if (identity.displayName != profile.displayName) {
        await setDisplayName(profile.displayName);
      }

      if (profile.passRecord == null) {
        // Profile exists but no password (shouldn't happen on the happy path —
        // an export from a pre-password build would land here). Treat as
        // already authed.
        state = AuthAuthed(_userFromProfile(identity.peerId, profile));
        return;
      }

      // Try biometric auto-unlock (mobile only, when the user enabled it).
      // Any failure path leaves the vault locked → password screen. We NEVER
      // mark authed without a real KEK from the secure keystore.
      if (await _tryBiometricUnlock(identity.peerId, profile)) return;

      // "Remember me" auto-unlock (web): if a remembered KEK is on file and
      // still matches the stored record, install it and skip the lock screen.
      // We verify the cached KEK against the record's HMAC verifier first (one
      // HMAC, no scrypt) so a stale/corrupt value can't slip through and break
      // at-rest decryption downstream — on mismatch we forget it and fall back
      // to the password screen.
      if (await remembered.isRememberSupported()) {
        final stored = ScryptStoredRecord.fromJson(profile.passRecord!);
        final kek = await remembered.loadKek();
        if (stored != null &&
            kek != null &&
            kek.length >= 32 &&
            await kekMatchesRecord(kek, stored)) {
          await setVaultKek(kek);
          state = AuthAuthed(_userFromProfile(identity.peerId, profile));
          return;
        }
        // No usable remembered session — drop any stale entry.
        await remembered.clearRememberedKek();
      }

      state = AuthLocked(profile);
    } catch (_) {
      // Any bootstrap failure → fall back to guest so the user can re-create
      // a profile instead of being stuck on a splash.
      state = const AuthGuest();
    }
  }

  /// Attempt to unlock the vault from the OS biometric keystore. Returns true
  /// (and sets [AuthAuthed]) only when a real KEK was retrieved; false on every
  /// other path so the caller shows the password screen.
  Future<bool> _tryBiometricUnlock(String peerId, LocalProfile profile) async {
    try {
      if (!_autoUnlock.isSupported) return false;
      if (!await _autoUnlock.isEnabled()) return false;
      if (!await _autoUnlock.hasStoredKek()) return false;
      final result = await _autoUnlock.retrieve();
      if (!result.ok) return false;
      await setVaultKek(result.kek!);
      if (!mounted) return true;
      state = AuthAuthed(_userFromProfile(peerId, profile));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Enable/disable biometric auto-unlock. Enabling stores the CURRENT in-RAM
  /// KEK behind the biometric gate (requires the vault to be unlocked); it
  /// never stores the password. Returns true on success. No-op + false on
  /// unsupported platforms or when the vault is locked.
  Future<bool> setBiometricUnlock(bool enabled) async {
    if (enabled) {
      return _autoUnlock.enable(currentVaultKekBytes());
    }
    await _autoUnlock.disable();
    return true;
  }

  /// Current on/off state of biometric auto-unlock (false when unsupported).
  Future<bool> biometricUnlockEnabled() => _autoUnlock.isEnabled();

  /// Handle the final submit of the onboarding wizard. Derives a vault KEK,
  /// persists the password record, and transitions to [AuthAuthed].
  Future<AuthedUser> completeOnboarding({
    required String displayName,
    required String password,
    required String confirm,
    String? avatarDataUrl,
    bool remember = false,
  }) async {
    final vu = validateUsername(displayName);
    if (!vu.ok) {
      throw const AuthException('username', 'Ник: 3–30 символов, буквы/цифры/подчёркивание');
    }
    final vp = validatePassword(password);
    if (!vp.ok) {
      throw const AuthException('password', 'Пароль: минимум 8 символов');
    }
    final vc = validatePasswordConfirm(password, confirm);
    if (!vc.ok) {
      throw const AuthException('confirm', 'Пароли не совпадают');
    }
    final name = vu.value!;

    final identity = await setDisplayName(name);

    // Single scrypt pass — `dkBytes` seeds the KEK, everything else is
    // persisted as the profile's `passRecord`. No second scrypt run needed.
    final derived = await deriveScryptRecord(username: name, password: password);
    await setVaultKek(derived.dkBytes);

    // Persist for auto-unlock when the user opted in (no-op off-web).
    if (remember) {
      await remembered.persistKek(derived.dkBytes);
    } else {
      await remembered.clearRememberedKek();
    }

    final profile = LocalProfile(
      displayName: name,
      bio: '',
      avatarDataUrl: avatarDataUrl,
      passRecord: derived.toJson(),
      onboardedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await saveLocalProfile(profile);

    final user = _userFromProfile(identity.peerId, profile);
    state = AuthAuthed(user);
    return user;
  }

  /// Verify the stored scrypt record, seed the KEK on success, and migrate
  /// any v1 record to v2 on the way out. Transitions to [AuthAuthed].
  Future<AuthedUser> unlock({
    required String password,
    bool remember = false,
  }) async {
    final cur = state;
    if (cur is! AuthLocked) {
      throw const AuthException('no_profile', 'Нет профиля');
    }
    final profile = cur.profile;
    final rawRecord = profile.passRecord;
    if (rawRecord == null) {
      throw const AuthException('no_profile', 'Нет профиля');
    }
    final stored = ScryptStoredRecord.fromJson(rawRecord);
    if (stored == null) {
      throw const AuthException('corrupt_record', 'Повреждённый профиль');
    }

    final result = await verifyScryptRecordEx(
      username: profile.displayName,
      password: password,
      record: stored,
    );
    if (!result.ok || result.dkBytes == null) {
      throw const AuthException('bad_password', 'Неверный пароль');
    }
    await setVaultKek(result.dkBytes!);

    // Honor the "Remember me" choice: persist the KEK for auto-unlock, or wipe
    // any prior remembered session if the box is unchecked. No-op off-web.
    if (remember) {
      await remembered.persistKek(result.dkBytes!);
    } else {
      await remembered.clearRememberedKek();
    }

    // v1 → v2 migration — re-derive with the stored cost parameters so the
    // next unlock reads a safe record. Failure is non-fatal; we'll try again
    // next time the user signs in.
    final storedVersion = (rawRecord['v'] as num?)?.toInt() ?? 1;
    if (storedVersion != 2) {
      try {
        final fresh = await deriveScryptRecord(
          username: profile.displayName,
          password: password,
          params: ScryptParams(
            n: stored.n,
            r: stored.r,
            p: stored.p,
            dkLen: stored.dkLen,
          ),
        );
        await saveLocalProfile(profile.copyWith(passRecord: fresh.toJson()));
      } catch (_) {
        // Swallow — we can retry migration on the next unlock.
      }
    }

    // Keep the biometric-keystore copy of the KEK fresh (no-op unless the user
    // enabled biometric unlock on a supported platform). Never stores password.
    await _autoUnlock.refresh(currentVaultKekBytes());

    final identity = await getOrCreateIdentity();
    final user = _userFromProfile(identity.peerId, profile);
    state = AuthAuthed(user);
    return user;
  }

  /// Auto-lock: re-lock the vault WITHOUT signing out. Clears the in-memory
  /// KEK (so at-rest secrets become unreadable) and returns to the password
  /// screen, keeping the profile and all data on disk. No-op unless currently
  /// authed and a password record exists (otherwise there's nothing to unlock
  /// back into). Does NOT touch the biometric-keystore copy — the user can
  /// re-unlock by password or biometrics.
  Future<void> lock() async {
    final cur = state;
    if (cur is! AuthAuthed) return;
    final profile = await loadLocalProfile();
    if (profile == null || profile.passRecord == null) return;
    clearVaultKek();
    if (!mounted) return;
    state = AuthLocked(profile);
  }

  /// Sign out: clear the KEK and profile but keep the peerId / crypto keys.
  /// The user can onboard again to the same device without losing peer
  /// pins or TOFU history (that's what [wipeLocal] is for).
  ///
  /// Locking the vault (clearing the KEK) is what makes the at-rest secrets
  /// unreadable again — message/peer rows stay on disk (intended: history
  /// survives a re-login to the *same* identity) but the ratchet/identity
  /// secrets are KEK-wrapped and inert until the next unlock. In-memory
  /// session state (typing bubbles, blocked mirror) is reset by
  /// `MessagingNotifier`'s auth listener on the authed→guest transition, so it
  /// can't bleed across a logout (audit H4).
  Future<void> logout() async {
    clearVaultKek();
    // Drop both auto-unlock copies — a logged-out device must not auto-unlock
    // back into the (now cleared) session.
    await _autoUnlock.clear();
    await remembered.clearRememberedKek();
    await clearLocalProfile();
    state = const AuthGuest();
  }

  /// Full reset: clears the profile, every local store, AND the cryptographic
  /// identity, so the next onboarding creates a brand-new peerId. Use for
  /// "Сбросить профиль" on the unlock screen when the user has forgotten their
  /// password. Order matters: wipe the DB (identity keys, prekeys, ratchets,
  /// pins, messages, peers, kv/auth-token) first, then drop the in-memory
  /// identity caches so a stale key pair can't shadow the wiped store, then
  /// regenerate the peerId (audit H4).
  Future<void> wipeLocal() async {
    clearVaultKek();
    await _autoUnlock.clear();
    await remembered.clearRememberedKek();
    await clearLocalProfile();
    try {
      await db.clearAllData();
    } catch (_) {
      // Best-effort — a DB error shouldn't trap the user on the lock screen.
    }
    identity_key.resetIdentityCaches();
    await resetIdentity();
    state = const AuthGuest();
  }

  /// Sentinel to differentiate "leave avatar alone" from "clear it" in
  /// [updateProfile]. Callers pass `removeAvatar: true` to clear, or set
  /// `avatarDataUrl` to a fresh data URL to replace.
  static const Object _avatarKeep = Object();

  /// Update displayName / bio / avatar. Any field left at its default is
  /// kept as-is. Pass `removeAvatar: true` to wipe the avatar; pass
  /// `avatarDataUrl: '...'` to replace it. Pass neither to keep the
  /// existing avatar untouched.
  ///
  /// Mirrors the JS three-way contract from `AuthContext.jsx`
  /// (`updateProfile({ avatarFile, removeAvatar, ...rest })`).
  Future<void> updateProfile({
    String? displayName,
    String? bio,
    Object? avatarDataUrl = _avatarKeep,
    bool removeAvatar = false,
  }) async {
    final cur = state;
    if (cur is! AuthAuthed) return;

    final name = displayName?.trim().isNotEmpty == true
        ? displayName!.trim()
        : cur.user.displayName;
    if (name != cur.user.displayName) {
      await setDisplayName(name);
    }

    // Resolve the next avatar value via the three-way ladder:
    //  1. removeAvatar=true wins, sets to null.
    //  2. avatarDataUrl was provided (not the keep-sentinel) → use it.
    //  3. otherwise carry over the existing avatar.
    final String? nextAvatar;
    if (removeAvatar) {
      nextAvatar = null;
    } else if (!identical(avatarDataUrl, _avatarKeep)) {
      nextAvatar = avatarDataUrl as String?;
    } else {
      nextAvatar = cur.user.avatarDataUrl;
    }

    final existing = await loadLocalProfile();
    final base = existing ?? LocalProfile(displayName: name, bio: cur.user.bio);
    final nextProfile = base.copyWith(
      displayName: name,
      bio: bio ?? cur.user.bio,
      avatarDataUrl: nextAvatar,
    );
    await saveLocalProfile(nextProfile);

    state = AuthAuthed(AuthedUser(
      peerId: cur.user.peerId,
      displayName: name,
      bio: nextProfile.bio,
      avatarDataUrl: nextProfile.avatarDataUrl,
    ));
  }

  AuthedUser _userFromProfile(String peerId, LocalProfile profile) =>
      AuthedUser(
        peerId: peerId,
        displayName: profile.displayName,
        bio: profile.bio,
        avatarDataUrl: profile.avatarDataUrl,
      );
}

/// Biometric auto-unlock service. Overridable in tests. Real impl on mobile,
/// stub (unsupported) on web/desktop.
final autoUnlockServiceProvider =
    Provider<AutoUnlockService>((ref) => createAutoUnlockService());

/// Session-root provider. `StateNotifierProvider` is keepAlive by default —
/// exactly what we want for the auth state sitting above everything.
final authNotifierProvider =
    StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(autoUnlock: ref.watch(autoUnlockServiceProvider)),
);
