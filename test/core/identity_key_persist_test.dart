// Identity keys must remain usable for wireHello even when persist fails
// (locked vault / wrapping error). Persist-before-cache used to fail-close
// the handshake, leaving 1:1 text stuck at status=pending.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/identity_key.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/core/vault_kek.dart';

class _ThrowingPutStore extends InMemoryKeyStore {
  @override
  Future<void> put(String table, Map<String, Object?> value) async {
    throw StateError('persist failed');
  }
}

Uint8List _key32() =>
    Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 1) & 0xff));

void main() {
  setUp(() {
    resetIdentityCaches();
    setKeyStore(InMemoryKeyStore());
    clearVaultKek();
  });

  tearDown(() {
    resetIdentityCaches();
    setKeyStore(InMemoryKeyStore());
    clearVaultKek();
  });

  test('getOrCreateSigningKey still signs when the vault is locked', () async {
    expect(hasVaultKek(), isFalse);
    final pair = await getOrCreateSigningKey();
    expect(pair, isNotNull);
    final sig = await signBytes(Uint8List.fromList([1, 2, 3, 4]));
    expect(sig, isNotEmpty);
    expect(await keyStore().get('keys', 'identity-signing-v1'), isNull);
  });

  test('getOrCreateSigningKey still signs when put() throws', () async {
    await setVaultKek(_key32());
    setKeyStore(_ThrowingPutStore());
    final pair = await getOrCreateSigningKey();
    expect(pair, isNotNull);
    final sig = await signBytes(Uint8List.fromList([9, 8, 7]));
    expect(sig.length, 64);
  });

  test('getOrCreateSigningKey persists when the vault is unlocked', () async {
    await setVaultKek(_key32());
    await getOrCreateSigningKey();
    final row = await keyStore().get('keys', 'identity-signing-v1');
    expect(row, isNotNull);
    expect(row!['id'], 'identity-signing-v1');
    expect(row['privEnc'], 1);
    expect(row['pubSpki'], isA<List<int>>());
  });

  test('reload after persist uses the same public key', () async {
    await setVaultKek(_key32());
    final first = await exportIdentityPubSpki();
    resetIdentityCaches();
    final second = await exportIdentityPubSpki();
    expect(second, equals(first));
  });
}
