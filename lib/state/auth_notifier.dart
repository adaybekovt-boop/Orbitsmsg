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
//   • Scrypt blocks for ~400–800 ms. A future optimization is wrapping
//     `deriveScryptRecord` / `verifyScryptRecordEx` in `Isolate.run`, but the
//     `cryptography_flutter` HMAC backend uses platform channels which don't
//     work off the main isolate. We accept the brief hitch for now and show a
//     spinner — callers see `busy=true` via the action Future.
//   • `reserveName` / registry.js is skipped: that was a browser-era concern
//     about multiple profiles sharing the same origin. On mobile the device
//     is the profile.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth_validation.dart';
import '../core/identity.dart';
import '../core/scrypt_kdf.dart';
import '../core/vault_kek.dart';
import '../storage/secure_profile_store.dart';

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
  AuthNotifier() : super(const AuthLoading()) {
    // Fire-and-forget — the state transitions to guest/locked/authed when
    // `_bootstrap()` resolves. AuthGate shows a splash while we're loading.
    _bootstrap();
  }

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

      state = AuthLocked(profile);
    } catch (_) {
      // Any bootstrap failure → fall back to guest so the user can re-create
      // a profile instead of being stuck on a splash.
      state = const AuthGuest();
    }
  }

  /// Handle the final submit of the onboarding wizard. Derives a vault KEK,
  /// persists the password record, and transitions to [AuthAuthed].
  Future<AuthedUser> completeOnboarding({
    required String displayName,
    required String password,
    required String confirm,
    String? avatarDataUrl,
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
  Future<AuthedUser> unlock({required String password}) async {
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

    // Use the username captured at derivation time, not the current
    // displayName — otherwise renaming the profile changes the KDF input and
    // permanently locks the user out. Older records that predate the stored
    // field fall back to the displayName they were created with.
    final kdfUsername = stored.kdfUsername ?? profile.displayName;

    final result = await verifyScryptRecordEx(
      username: kdfUsername,
      password: password,
      record: stored,
    );
    if (!result.ok || result.dkBytes == null) {
      throw const AuthException('bad_password', 'Неверный пароль');
    }
    await setVaultKek(result.dkBytes!);

    // Migration: re-derive when the record is v1 (legacy raw-dk) OR is missing
    // the persisted KDF username, so the next unlock survives a future rename.
    // Re-derivation reuses the stored cost parameters and the resolved
    // username; failure is non-fatal and retried on the next sign-in.
    final storedVersion = (rawRecord['v'] as num?)?.toInt() ?? 1;
    if (storedVersion != 2 || stored.kdfUsername == null) {
      try {
        final fresh = await deriveScryptRecord(
          username: kdfUsername,
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

    final identity = await getOrCreateIdentity();
    final user = _userFromProfile(identity.peerId, profile);
    state = AuthAuthed(user);
    return user;
  }

  /// Sign out: clear the KEK and profile but keep the peerId / crypto keys.
  /// The user can onboard again to the same device without losing peer
  /// pins or TOFU history (that's what [wipeLocal] is for).
  Future<void> logout() async {
    clearVaultKek();
    await clearLocalProfile();
    // TODO: stopPrekeyMaintenance() once ported.
    // TODO: clear Drift messages/peer rows once those providers exist.
    state = const AuthGuest();
  }

  /// Full reset: clears the profile AND the cryptographic identity, so the
  /// next onboarding creates a brand-new peerId. Use for "Сбросить профиль"
  /// on the unlock screen when the user has forgotten their password.
  Future<void> wipeLocal() async {
    clearVaultKek();
    await clearLocalProfile();
    await resetIdentity();
    // TODO: wipe KeyStore tables (identity keys, prekeys, ratchets) and the
    // Drift message/peer rows. Those helpers live in slices we haven't
    // finished yet.
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

/// Session-root provider. `StateNotifierProvider` is keepAlive by default —
/// exactly what we want for the auth state sitting above everything.
final authNotifierProvider =
    StateNotifierProvider<AuthNotifier, AuthState>((ref) => AuthNotifier());
