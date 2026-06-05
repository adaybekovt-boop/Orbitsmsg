// Bootstrap "Remember me" auto-unlock (native/desktop): with a remembered KEK on
// file, a fresh launch unlocks WITHOUT a password — but ONLY when that KEK still
// matches the stored scrypt record. A stale/mismatched KEK is forgotten and the
// vault stays locked (the user types the password). Deterministic + offline:
// in-memory Drift DB, mocked SharedPreferences, an UNSUPPORTED biometric service
// (so bootstrap reaches the remember branch regardless of host OS), and a fake
// remembered store (the OS secure-storage plugin isn't available under test).
//
// The profile uses a v1 scrypt record (raw `dkB64`), so `kekMatchesRecord` is a
// plain base64 compare — a matching (kek, record) pair without running scrypt.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:orbits_flutter/core/identity.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/state/auth_notifier.dart';
import 'package:orbits_flutter/state/auto_unlock_service.dart';
import 'package:orbits_flutter/state/remembered_session_io.dart' as remembered;
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/secure_profile_store.dart';

/// Unsupported biometric service → bootstrap falls through to the remember
/// branch on any host OS (the real default is already unsupported on desktop).
class _NoBiometric implements AutoUnlockService {
  @override
  bool get isSupported => false;
  @override
  Future<bool> isEnabled() async => false;
  @override
  Future<bool> hasStoredKek() async => false;
  @override
  Future<AutoUnlockResult> retrieve() async =>
      const AutoUnlockResult(AutoUnlockStatus.unavailable);
  @override
  Future<bool> enable(Uint8List? kekBytes) async => false;
  @override
  Future<void> disable() async {}
  @override
  Future<void> refresh(Uint8List? kekBytes) async {}
  @override
  Future<void> clear() async {}
}

class _FakeStore implements remembered.RememberedKekStore {
  bool isAvailable = true;
  String? value;
  int deletes = 0;

  @override
  Future<bool> available() async => isAvailable;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async {
    deletes++;
    value = null;
  }
}

void main() {
  late OrbitsDatabase database;
  late _FakeStore store;

  // What a healthy remembered store would hand back on a cold launch.
  final kek =
      Uint8List.fromList(List<int>.generate(32, (i) => (i * 5 + 1) & 0xff));

  // A v1 record whose raw dk == [k], so kekMatchesRecord([k], record) is true.
  LocalProfile profileForKek(List<int> k) => LocalProfile(
        displayName: 'Tester',
        passRecord: <String, Object?>{
          'algo': 'scrypt',
          'v': 1,
          'saltB64': base64Encode(List<int>.filled(16, 3)),
          'N': 16384,
          'r': 8,
          'p': 1,
          'dkLen': 32,
          'dkB64': base64Encode(k),
        },
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    // Seed the identity (peerId is public, SharedPreferences-backed) while a KEK
    // is set, then the tests simulate a cold launch by clearing it.
    await setVaultKek(List<int>.generate(32, (i) => (i + 1) & 0xff));
    await getOrCreateIdentity();
    store = _FakeStore();
    remembered.debugRememberedKekStore = store;
  });

  tearDown(() async {
    remembered.debugRememberedKekStore = null;
    clearVaultKek();
    await closeOrbitsDatabase();
  });

  ProviderContainer boot() {
    final c = ProviderContainer(
      overrides: [autoUnlockServiceProvider.overrideWithValue(_NoBiometric())],
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

  test('a matching remembered KEK auto-unlocks WITHOUT a password', () async {
    await saveLocalProfile(profileForKek(kek));
    store.value = base64Encode(kek); // healthy remembered session
    clearVaultKek(); // cold launch — no in-RAM KEK

    final s = await settle(boot());

    expect(s, isA<AuthAuthed>(),
        reason: 'a remembered KEK that matches the record should unlock');
    expect(hasVaultKek(), isTrue);
    expect(currentVaultKekBytes(), kek,
        reason: 'the installed KEK is the remembered one');
    expect(store.deletes, 0, reason: 'a valid session is kept, not cleared');
  });

  test('a stale remembered KEK is forgotten and the vault stays locked',
      () async {
    await saveLocalProfile(profileForKek(kek)); // record matches `kek`…
    final wrong =
        Uint8List.fromList(List<int>.generate(32, (i) => (i + 99) & 0xff));
    store.value = base64Encode(wrong); // …but the store holds a DIFFERENT KEK
    clearVaultKek();

    final s = await settle(boot());

    expect(s, isA<AuthLocked>(), reason: 'a mismatched KEK must not unlock');
    expect(hasVaultKek(), isFalse);
    expect(store.deletes, greaterThanOrEqualTo(1),
        reason: 'a stale remembered KEK is cleared');
  });

  test('no remembered KEK → stays locked (normal password launch)', () async {
    await saveLocalProfile(profileForKek(kek));
    store.value = null; // nothing remembered
    clearVaultKek();

    final s = await settle(boot());

    expect(s, isA<AuthLocked>());
    expect(hasVaultKek(), isFalse);
  });

  test('remember unsupported → bootstrap never reads the store, stays locked',
      () async {
    await saveLocalProfile(profileForKek(kek));
    store
      ..value = base64Encode(kek)
      ..isAvailable = false; // e.g. mobile, or a backend that isn't available
    clearVaultKek();

    final s = await settle(boot());

    expect(s, isA<AuthLocked>());
    expect(hasVaultKek(), isFalse);
  });
}
