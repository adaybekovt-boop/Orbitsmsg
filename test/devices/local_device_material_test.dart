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
    expect(first.transportPublicKey, hasLength(32));
    expect(first.hypercorePublicKey, hasLength(32));
    expect(first.transportPublicKey, isNot(first.hypercorePublicKey));
    expect(first.transportPublicKey.toSet(), isNot(hasLength(1)));
    expect(first.hypercorePublicKey.toSet(), isNot(hasLength(1)));

    final again = await loadOrCreateLocalDeviceMaterial(store: store);
    expect(again.deviceId, first.deviceId);
    expect(again.transportPublicKey, first.transportPublicKey);
    expect(again.hypercorePublicKey, first.hypercorePublicKey);
  });

  test('placeholder and empty identity material are rejected', () async {
    final store = InMemoryKeyStore();
    await store.put('device-material', {
      'id': 'local',
      'deviceId': 'local-device',
      'transportPublicKey': List<int>.filled(32, 1),
      'hypercorePublicKey': List<int>.filled(32, 2),
    });
    final replaced = await loadOrCreateLocalDeviceMaterial(store: store);
    expect(replaced.deviceId, isNot('local-device'));
    expect(replaced.transportPublicKey.toSet(), isNot(equals({1})));
    expect(replaced.hypercorePublicKey.toSet(), isNot(equals({2})));
  });

  test('issued binding carries real keys and a signature', () async {
    final store = InMemoryKeyStore();
    final material = await loadOrCreateLocalDeviceMaterial(store: store);
    final pair = await generateP256EcdsaKey();
    final identity = buildP256Spki(x: pair.x, y: pair.y);
    final now = DateTime.now().millisecondsSinceEpoch;
    final binding = await issueLocalDeviceBinding(
      material: material,
      capabilities: const ['hyperswarm-v1'],
      createdAt: now,
      expiresAt: now + 60 * 1000,
      exportIdentity: () async => identity,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    expect(binding.identityPublicKey, identity);
    expect(binding.transportPublicKey, material.transportPublicKey);
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
    expect(a.transportPublicKey, isNot(b.transportPublicKey));
    expect(a.hypercorePublicKey, isNot(b.hypercorePublicKey));
  });
}
