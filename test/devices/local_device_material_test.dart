import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/devices/local_device_material.dart';
import 'package:orbits_flutter/transport/device_binding.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
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

  test('two devices never share transport or writer keys', () async {
    final a = await loadOrCreateLocalDeviceMaterial(store: InMemoryKeyStore());
    final b = await loadOrCreateLocalDeviceMaterial(store: InMemoryKeyStore());
    expect(a.deviceId, isNot(b.deviceId));
    expect(a.transportSecretSeed, isNot(b.transportSecretSeed));
    expect(a.hypercorePublicKey, isNot(b.hypercorePublicKey));
  });
}
