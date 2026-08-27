// R6-01 / R6-02 / R6-03 — vault password wrap must survive rename and
// logout, and a v1→v2 upgrade must not mint a new salt.
//
// Each test is "data existed → action → data still there", not "no throw".

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:orbits_flutter/core/base64_helpers.dart';
import 'package:orbits_flutter/core/identity.dart';
import 'package:orbits_flutter/core/scrypt_kdf.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/state/auth_notifier.dart';
import 'package:orbits_flutter/state/auto_unlock_service.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/secure_profile_store.dart';

class _NoBio implements AutoUnlockService {
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

void main() {
  late OrbitsDatabase database;
  const fast = ScryptParams(n: scryptMinN);
  const password = 'Correct-horse-1';
  const note = 'vault-secret-r6-auth';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await getOrCreateIdentity();
  });

  tearDown(() async {
    clearVaultKek();
    await closeOrbitsDatabase();
  });

  ProviderContainer boot() {
    final c = ProviderContainer(
      overrides: [autoUnlockServiceProvider.overrideWithValue(_NoBio())],
    );
    addTearDown(c.dispose);
    c.read(authNotifierProvider);
    return c;
  }

  Future<AuthState> settle(ProviderContainer c) async {
    for (var i = 0; i < 400; i++) {
      final s = c.read(authNotifierProvider);
      if (s is! AuthLoading) return s;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return c.read(authNotifierProvider);
  }

  Future<void> putLegacyProfile({
    required String displayName,
    required Map<String, Object?> passRecord,
  }) async {
    await saveLocalProfile(LocalProfile(
      displayName: displayName,
      passRecord: passRecord,
    ));
    clearVaultKek();
  }

  group('R6-01 displayName is not the KDF id', () {
    test('legacy record: rename then unlock still decrypts wrapped data',
        () async {
      final rec = await deriveScryptRecord(
        username: 'AliceUser',
        password: password,
        params: fast,
      );
      final legacy = Map<String, Object?>.from(rec.toJson())..remove('kdfId');
      await putLegacyProfile(displayName: 'AliceUser', passRecord: legacy);

      final c = boot();
      expect(await settle(c), isA<AuthLocked>());

      await c.read(authNotifierProvider.notifier).unlock(password: password);
      expect(c.read(authNotifierProvider), isA<AuthAuthed>());

      final wrapped = await wrapSecret(utf8.encode(note));
      final stamped = await loadLocalProfile();
      expect(stamped!.passRecord!['kdfId'], 'AliceUser',
          reason: 'first unlock must freeze the username that worked');

      await c
          .read(authNotifierProvider.notifier)
          .updateProfile(displayName: 'BobThePeer');
      expect((await loadLocalProfile())!.displayName, 'BobThePeer');
      expect((await loadLocalProfile())!.passRecord!['kdfId'], 'AliceUser');
      expect((await loadLocalProfile())!.passRecord!['saltB64'], rec.saltB64);

      await c.read(authNotifierProvider.notifier).lock();
      expect(c.read(authNotifierProvider), isA<AuthLocked>());
      expect(hasVaultKek(), isFalse);

      await c.read(authNotifierProvider.notifier).unlock(password: password);
      expect(utf8.decode(await unwrapSecret(wrapped)), note);
      expect((c.read(authNotifierProvider) as AuthAuthed).user.displayName,
          'BobThePeer');
    });

    test('new record (kdfId=orbits): rename does not change the wrap',
        () async {
      final rec = await deriveScryptRecord(
        username: kScryptStableKdfId,
        password: password,
        params: fast,
      );
      await putLegacyProfile(
        displayName: 'AliceUser',
        passRecord: rec.toJson(),
      );

      final c = boot();
      await settle(c);
      await c.read(authNotifierProvider.notifier).unlock(password: password);
      final wrapped = await wrapSecret(utf8.encode(note));

      await c
          .read(authNotifierProvider.notifier)
          .updateProfile(displayName: 'BobThePeer');
      await c.read(authNotifierProvider.notifier).lock();
      await c.read(authNotifierProvider.notifier).unlock(password: password);

      expect(utf8.decode(await unwrapSecret(wrapped)), note);
      expect((await loadLocalProfile())!.passRecord!['kdfId'],
          kScryptStableKdfId);
    });
  });

  group('R6-02 logout keeps the profile; wipeLocal destroys it', () {
    test('logout then unlock still decrypts; wipeLocal drops the profile',
        () async {
      final rec = await deriveScryptRecord(
        username: kScryptStableKdfId,
        password: password,
        params: fast,
      );
      await putLegacyProfile(
        displayName: 'AliceUser',
        passRecord: rec.toJson(),
      );

      final c = boot();
      await settle(c);
      await c.read(authNotifierProvider.notifier).unlock(password: password);
      final wrapped = await wrapSecret(utf8.encode(note));

      await c.read(authNotifierProvider.notifier).logout();
      expect(c.read(authNotifierProvider), isA<AuthLocked>(),
          reason: 'logout is a session lock, not a wipe');
      expect(hasVaultKek(), isFalse);
      final kept = await loadLocalProfile();
      expect(kept, isNotNull);
      expect(kept!.passRecord, isNotNull);
      expect(kept.displayName, 'AliceUser');

      await c.read(authNotifierProvider.notifier).unlock(password: password);
      expect(utf8.decode(await unwrapSecret(wrapped)), note);

      await c.read(authNotifierProvider.notifier).wipeLocal();
      expect(c.read(authNotifierProvider), isA<AuthGuest>());
      expect(await loadLocalProfile(), isNull);
    });
  });

  group('R6-03 v1→v2 keeps the same salt and KEK', () {
    test('unlock upgrades v1 in place; second unlock decrypts the same wrap',
        () async {
      final rec = await deriveScryptRecord(
        username: 'AliceUser',
        password: password,
        params: fast,
      );
      final v1 = <String, Object?>{
        'algo': 'scrypt',
        'v': 1,
        'saltB64': rec.saltB64,
        'N': rec.n,
        'r': rec.r,
        'p': rec.p,
        'dkLen': rec.dkLen,
        'dkB64': bytesToBase64(rec.dkBytes),
      };
      await putLegacyProfile(displayName: 'AliceUser', passRecord: v1);

      final c = boot();
      await settle(c);
      await c.read(authNotifierProvider.notifier).unlock(password: password);
      final wrapped = await wrapSecret(utf8.encode(note));

      final upgraded = (await loadLocalProfile())!.passRecord!;
      expect(upgraded['saltB64'], rec.saltB64,
          reason: 'v1→v2 must not mint a new salt');
      expect(upgraded['v'], 2);
      expect(upgraded['dkB64'], isNull);
      expect(upgraded['verifierB64'], isNotNull);
      expect(upgraded['N'], rec.n);

      await c.read(authNotifierProvider.notifier).lock();
      await c.read(authNotifierProvider.notifier).unlock(password: password);
      expect(utf8.decode(await unwrapSecret(wrapped)), note);
    });

    test('interrupted migrate: leftover v1 or in-place v2 both decrypt',
        () async {
      final rec = await deriveScryptRecord(
        username: 'AliceUser',
        password: password,
        params: fast,
      );
      final v1 = <String, Object?>{
        'algo': 'scrypt',
        'v': 1,
        'saltB64': rec.saltB64,
        'N': rec.n,
        'r': rec.r,
        'p': rec.p,
        'dkLen': rec.dkLen,
        'dkB64': bytesToBase64(rec.dkBytes),
      };

      // Crash before rewrite: still v1.
      final stillV1 = ScryptStoredRecord.fromJson(v1)!;
      final a = await verifyScryptRecordEx(
        username: 'AliceUser',
        password: password,
        record: stillV1,
      );
      expect(a.ok, isTrue);
      await setVaultKek(a.dkBytes!);
      final wrapped = await wrapSecret(utf8.encode(note));
      clearVaultKek();

      // Crash after rewrite: v2, same salt.
      final rewritten = await persistableScryptRecord(
        record: stillV1,
        dkBytes: a.dkBytes!,
        kdfId: 'AliceUser',
      );
      expect(rewritten['saltB64'], rec.saltB64);
      final v2 = ScryptStoredRecord.fromJson(rewritten)!;
      final b = await verifyScryptRecordEx(
        username: 'AliceUser',
        password: password,
        record: v2,
      );
      expect(b.ok, isTrue);
      await setVaultKek(b.dkBytes!);
      expect(utf8.decode(await unwrapSecret(wrapped)), note);
    });
  });
}
