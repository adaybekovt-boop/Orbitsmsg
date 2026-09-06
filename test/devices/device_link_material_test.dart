import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/devices/device_link.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/devices/local_device_material.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  setUp(resetDeviceLinkChallengesForTests);

  test('two devices have different ids and QR has no private key', () async {
    final a = await loadOrCreateLocalDeviceMaterial(store: InMemoryKeyStore());
    final b = await loadOrCreateLocalDeviceMaterial(store: InMemoryKeyStore());
    expect(a.deviceId, isNot(b.deviceId));
    expect(a.transportPublicKey, isNot(List<int>.filled(32, 1)));
    expect(a.hypercorePublicKey, isNot(List<int>.filled(32, 2)));
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final link = await issueLocalDeviceLink(
      material: a,
      ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    final encoded = jsonEncode(link.toQrJson()).toLowerCase();
    expect(encoded.contains('priv'), isFalse);
    expect(encoded.contains('secretseed'), isFalse);
    expect(link.deviceId, a.deviceId);
    expect(link.transportPublicKey, a.transportPublicKey);
    expect(link.hypercorePublicKey, a.hypercorePublicKey);
    expect(link.challenge, isNotEmpty);
  });

  test('tampered, replayed, expired, and placeholder links are rejected', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final material = await loadOrCreateLocalDeviceMaterial(store: InMemoryKeyStore());
    final link = await issueLocalDeviceLink(
      material: material,
      ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    expect(await verifyDeviceLink(link), isTrue);
    final tampered = DeviceLinkPayload.fromQrJson({
      ...link.toQrJson(),
      'deviceId': 'other-device',
    });
    expect(await verifyDeviceLink(tampered), isFalse);
    final registry = DeviceRegistry();
    expect(
      await acceptDeviceLink(
        link,
        ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        registry: registry,
      ),
      isTrue,
    );
    expect(
      await acceptDeviceLink(
        link,
        ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        registry: registry,
      ),
      isFalse,
    );
    expect(
      await verifyDeviceLink(link, nowMs: link.expiresAt + 1),
      isFalse,
    );
    final stub = await issueDeviceLink(
      deviceId: 'local-device',
      transportPublicKey: Uint8List.fromList(List<int>.filled(32, 1)),
      hypercorePublicKey: Uint8List.fromList(List<int>.filled(32, 2)),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
      ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
    );
    expect(
      await acceptDeviceLink(
        stub,
        ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        registry: DeviceRegistry(),
      ),
      isFalse,
    );
  });

  test('QR JSON with private material is rejected', () {
    expect(
      () => DeviceLinkPayload.fromQrJson({
        'v': kDeviceLinkInfo,
        'deviceId': 'x',
        'priv': 'secret',
      }),
      throwsFormatException,
    );
  });
}
