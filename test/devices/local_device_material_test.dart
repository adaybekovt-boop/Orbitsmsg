import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/base64_helpers.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/devices/local_device_material.dart';
import 'package:orbits_flutter/transport/device_binding.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  setUp(() async {
    await setVaultKek(List<int>.generate(32, (i) => (i * 5 + 3) & 0xff));
  });
  tearDown(clearVaultKek);
  test('restart loads the same distinct device material', () async {
    final store = InMemoryKeyStore();
    final first = await loadOrCreateLocalDeviceMaterial(store: store);
    expect(first.transportSecretSeed, hasLength(32));
    expect(first.hypercorePublicKey, hasLength(32));
    expect(first.transportSecretSeed, isNot(first.hypercorePublicKey));
    expect(first.transportSecretSeed.toSet(), isNot(hasLength(1)));
    expect(first.hypercorePublicKey.toSet(), isNot(hasLength(1)));

    final again = await loadOrCreateLocalDeviceMaterial(store: store);
    expect(again.deviceId, first.deviceId);
    expect(again.transportSecretSeed, first.transportSecretSeed);
    expect(again.hypercorePublicKey, first.hypercorePublicKey);
  });

  test('placeholder and empty identity material are rejected', () async {
    final store = InMemoryKeyStore();
    await store.put('device-material', {
      'id': 'local',
      'deviceId': 'local-device',
      'transportPublicKey': List<int>.filled(32, 1),
      'hypercorePublicKey': List<int>.filled(32, 2),
      'transportSecretSeed': List<int>.filled(32, 3),
    });
    final replaced = await loadOrCreateLocalDeviceMaterial(store: store);
    expect(replaced.deviceId, isNot('local-device'));
    expect(replaced.transportSecretSeed.toSet(), isNot(equals({3})));
    expect(replaced.hypercorePublicKey.toSet(), isNot(equals({2})));
  });

  test('issued binding carries real keys and a signature', () async {
    final store = InMemoryKeyStore();
    final material = await loadOrCreateLocalDeviceMaterial(store: store);
    final pair = await generateP256EcdsaKey();
    final identity = buildP256Spki(x: pair.x, y: pair.y);
    final now = DateTime.now().millisecondsSinceEpoch;
    final withKey = await rememberTransportPublicKey(
      material: material,
      transportPublicKey: List<int>.generate(32, (i) => i + 4),
      store: store,
    );
    final binding = await issueLocalDeviceBinding(
      material: withKey,
      capabilities: const ['hyperswarm-v1'],
      createdAt: now,
      expiresAt: now + 60 * 1000,
      ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      exportIdentity: () async => identity,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    expect(binding.identityPublicKey, identity);
    expect(binding.ownerPeerId, 'ORBIT-AAAAAAAAAAAAAAAA');
    expect(binding.transportPublicKey, withKey.transportPublicKey);
    expect(binding.hypercorePublicKey, material.hypercorePublicKey);
    expect(binding.signatureByIdentityKey, isNot(isEmpty));
    expect(deviceBindingClockIsValid(binding, nowMs: now), isTrue);
    expect(
      deviceBindingClockIsValid(binding, nowMs: binding.expiresAt + 1),
      isFalse,
    );
  });

  test(
    'rememberHypercorePublicKey persists a real 32-byte writer key',
    () async {
      final store = InMemoryKeyStore();
      final material = await loadOrCreateLocalDeviceMaterial(store: store);
      final next = List<int>.generate(32, (i) => i + 7);
      final updated = await rememberHypercorePublicKey(
        material: material,
        hypercorePublicKey: next,
        store: store,
      );
      expect(updated.hypercorePublicKey, next);
      expect(updated.deviceId, material.deviceId);
      expect(updated.transportPublicKey, material.transportPublicKey);

      final rejected = await rememberHypercorePublicKey(
        material: updated,
        hypercorePublicKey: List<int>.filled(16, 1),
        store: store,
      );
      expect(rejected.hypercorePublicKey, next);

      final reloaded = await loadOrCreateLocalDeviceMaterial(store: store);
      expect(reloaded.hypercorePublicKey, next);
    },
  );

  test('two devices never share transport or writer keys', () async {
    final a = await loadOrCreateLocalDeviceMaterial(store: InMemoryKeyStore());
    final b = await loadOrCreateLocalDeviceMaterial(store: InMemoryKeyStore());
    expect(a.deviceId, isNot(b.deviceId));
    expect(a.transportSecretSeed, isNot(b.transportSecretSeed));
    expect(a.hypercorePublicKey, isNot(b.hypercorePublicKey));
  });

  test('seed is wrapped at rest and legacy plaintext is resealed', () async {
    final store = InMemoryKeyStore();
    await loadOrCreateLocalDeviceMaterial(store: store);
    final row = await store.get('device-material', 'local');
    expect(row, isNotNull);
    expect(isWrapped(row!['transportSecretSeed']), isTrue);

    final legacy = InMemoryKeyStore();
    final seed = List<int>.generate(32, (i) => i + 1);
    final writer = List<int>.generate(32, (i) => 200 - i);
    final transport = List<int>.generate(32, (i) => 100 + i);
    await legacy.put('device-material', {
      'id': 'local',
      'deviceId': 'legacy-device',
      'transportPublicKey': bytesToBase64(Uint8List.fromList(transport)),
      'hypercorePublicKey': bytesToBase64(Uint8List.fromList(writer)),
      'transportSecretSeed': bytesToBase64(Uint8List.fromList(seed)),
    });
    final loaded = await loadOrCreateLocalDeviceMaterial(store: legacy);
    expect(loaded.deviceId, 'legacy-device');
    expect(loaded.transportSecretSeed, seed);
    final resealed = await legacy.get('device-material', 'local');
    expect(isWrapped(resealed!['transportSecretSeed']), isTrue);
  });
}
