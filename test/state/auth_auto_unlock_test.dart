// Auto-update / Settings honesty — biometric auto-unlock behavior.
//
// Proves the headline fix for the old write-only "remember password" toggle:
//   • a fresh launch unlocks WITHOUT a password only when the secure keystore
//     actually returns the KEK (supported + enabled + stored + retrieve ok);
//   • every other path stays LOCKED (never fake-authed);
//   • enabling stores the in-RAM KEK (never the password); disabling/logout
//     clear it;
//   • on this desktop host the REAL default service reports unsupported.
//
// Deterministic + offline: in-memory Drift DB, mocked SharedPreferences, and an
// injected fake AutoUnlockService (no real biometric / secure storage).

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:orbits_flutter/core/identity.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/state/auth_notifier.dart';
import 'package:orbits_flutter/state/auto_unlock_service.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/secure_profile_store.dart';

class _FakeAutoUnlock implements AutoUnlockService {
  _FakeAutoUnlock({
    this.supported = false,
    this.enabled = false,
    this.stored = false,
    this.retrieveResult,
  });

  bool supported;
  bool enabled;
  bool stored;
  AutoUnlockResult? retrieveResult;

  int enableCalls = 0;
  int disableCalls = 0;
  int clearCalls = 0;
  int refreshCalls = 0;
  int retrieveCalls = 0;
  Uint8List? lastEnabledKek;

  @override
  bool get isSupported => supported;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<bool> hasStoredKek() async => stored;

  @override
  Future<AutoUnlockResult> retrieve() async {
    retrieveCalls++;
    return retrieveResult ??
        const AutoUnlockResult(AutoUnlockStatus.unavailable);
  }

  @override
  Future<bool> enable(Uint8List? kekBytes) async {
    enableCalls++;
    lastEnabledKek = kekBytes;
    if (!supported || kekBytes == null || kekBytes.length != 32) return false;
    enabled = true;
    stored = true;
    return true;
  }

  @override
  Future<void> disable() async {
    disableCalls++;
    enabled = false;
    stored = false;
  }

  @override
  Future<void> refresh(Uint8List? kekBytes) async {
    refreshCalls++;
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    enabled = false;
    stored = false;
  }
}

void main() {
  late OrbitsDatabase database;

  const lockedProfile = LocalProfile(
    displayName: 'Tester',
    passRecord: <String, Object?>{
      'v': 2,
      'algo': 'scrypt',
      'saltB64': 'AAAA',
      'verifierB64': 'BBBB',
      'n': 16384,
      'r': 8,
      'p': 1,
      'dkLen': 32,
    },
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    // A KEK + identity must exist so bootstrap's getOrCreateIdentity reads an
    // existing identity (peerId is public). The locked profile drives bootstrap
    // to the password/biometric branch.
    await setVaultKek(List<int>.generate(32, (i) => (i + 1) & 0xff));
    await getOrCreateIdentity();
    await saveLocalProfile(lockedProfile);
  });

  tearDown(() async {
    clearVaultKek();
    await closeOrbitsDatabase();
  });

  ProviderContainer boot(_FakeAutoUnlock fake) {
    final c = ProviderContainer(
      overrides: [autoUnlockServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(c.dispose);
    c.read(authNotifierProvider); // force-create → runs _bootstrap()
    return c;
  }

  Future<AuthState> settle(ProviderContainer c) async {
    for (var i = 0; i < 200; i++) {
      final s = c.read(authNotifierProvider);
      if (s is! AuthLoading) return s;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return c.read(authNotifierProvider);
  }

  group('bootstrap auto-unlock decision', () {
    test('supported + enabled + stored + retrieve OK → AuthAuthed (no password)',
        () async {
      final fake = _FakeAutoUnlock(
        supported: true,
        enabled: true,
        stored: true,
        retrieveResult: AutoUnlockResult(
          AutoUnlockStatus.ok,
          kek: Uint8List.fromList(List<int>.generate(32, (i) => 7)),
        ),
      );
      final c = boot(fake);
      final s = await settle(c);
      expect(s, isA<AuthAuthed>());
      expect(fake.retrieveCalls, 1);
    });

    test('retrieve CANCELLED → stays AuthLocked (no fake auth)', () async {
      final fake = _FakeAutoUnlock(
        supported: true,
        enabled: true,
        stored: true,
        retrieveResult: const AutoUnlockResult(AutoUnlockStatus.cancelled),
      );
      final s = await settle(boot(fake));
      expect(s, isA<AuthLocked>());
    });

    test('retrieve INVALIDATED → stays AuthLocked', () async {
      final fake = _FakeAutoUnlock(
        supported: true,
        enabled: true,
        stored: true,
        retrieveResult: const AutoUnlockResult(AutoUnlockStatus.invalidated),
      );
      final s = await settle(boot(fake));
      expect(s, isA<AuthLocked>());
    });

    test('enabled but UNSUPPORTED platform → AuthLocked, no retrieve', () async {
      final fake = _FakeAutoUnlock(supported: false, enabled: true, stored: true);
      final s = await settle(boot(fake));
      expect(s, isA<AuthLocked>());
      expect(fake.retrieveCalls, 0);
    });

    test('supported but DISABLED → AuthLocked, no retrieve', () async {
      final fake = _FakeAutoUnlock(supported: true, enabled: false, stored: true);
      final s = await settle(boot(fake));
      expect(s, isA<AuthLocked>());
      expect(fake.retrieveCalls, 0);
    });

    test('enabled but NOTHING stored → AuthLocked, no retrieve', () async {
      final fake = _FakeAutoUnlock(supported: true, enabled: true, stored: false);
      final s = await settle(boot(fake));
      expect(s, isA<AuthLocked>());
      expect(fake.retrieveCalls, 0);
    });
  });

  group('setBiometricUnlock', () {
    test('enabling with an unlocked vault stores the 32-byte KEK (not password)',
        () async {
      final fake = _FakeAutoUnlock(supported: true);
      final c = boot(fake);
      await settle(c);
      await setVaultKek(List<int>.generate(32, (i) => (i * 3) & 0xff));

      final ok =
          await c.read(authNotifierProvider.notifier).setBiometricUnlock(true);

      expect(ok, isTrue);
      expect(fake.enableCalls, 1);
      expect(fake.lastEnabledKek, isNotNull);
      expect(fake.lastEnabledKek!.length, 32);
    });

    test('enabling while LOCKED (no KEK) fails — nothing stored', () async {
      final fake = _FakeAutoUnlock(supported: true);
      final c = boot(fake);
      await settle(c);
      clearVaultKek(); // simulate locked vault

      final ok =
          await c.read(authNotifierProvider.notifier).setBiometricUnlock(true);

      expect(ok, isFalse);
      expect(fake.lastEnabledKek, isNull);
    });

    test('disabling clears the stored KEK', () async {
      final fake = _FakeAutoUnlock(supported: true, enabled: true, stored: true);
      final c = boot(fake);
      await settle(c);

      final ok =
          await c.read(authNotifierProvider.notifier).setBiometricUnlock(false);

      expect(ok, isTrue);
      expect(fake.disableCalls, 1);
    });

    test('logout clears the secure keystore copy but keeps the profile',
        () async {
      final fake = _FakeAutoUnlock(supported: true, enabled: true, stored: true);
      final fakeAuthed = _FakeAutoUnlock(supported: true);
      // Use a locked bootstrap, then logout and assert clear() ran.
      final c = boot(fakeAuthed);
      await settle(c);
      await c.read(authNotifierProvider.notifier).logout();
      expect(fakeAuthed.clearCalls, 1);
      expect(await loadLocalProfile(), isNotNull,
          reason: 'R6-02: logout must not wipe passRecord');
      // (fake is unused beyond construction; keep analyzer happy)
      expect(fake.supported, isTrue);
    });
  });

  group('auto-lock (AuthNotifier.lock)', () {
    test('lock() clears the KEK and returns to AuthLocked (data preserved)',
        () async {
      final fake = _FakeAutoUnlock(
        supported: true,
        enabled: true,
        stored: true,
        retrieveResult: AutoUnlockResult(
          AutoUnlockStatus.ok,
          kek: Uint8List.fromList(List<int>.generate(32, (i) => 9)),
        ),
      );
      final c = boot(fake);
      expect(await settle(c), isA<AuthAuthed>());
      expect(hasVaultKek(), isTrue);

      await c.read(authNotifierProvider.notifier).lock();

      expect(c.read(authNotifierProvider), isA<AuthLocked>());
      expect(hasVaultKek(), isFalse); // KEK gone → at-rest secrets re-locked
      // Profile still on disk → can re-unlock by password.
      expect(await loadLocalProfile(), isNotNull);
    });
  });

  group('real default service on this desktop host', () {
    test('reports UNSUPPORTED and is a safe no-op', () async {
      final svc = createAutoUnlockService();
      expect(svc.isSupported, isFalse);
      expect(await svc.isEnabled(), isFalse);
      expect(await svc.hasStoredKek(), isFalse);
      expect(await svc.enable(Uint8List(32)), isFalse);
      expect((await svc.retrieve()).status, AutoUnlockStatus.unavailable);
    });
  });
}
