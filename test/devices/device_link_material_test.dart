import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/devices/device_link.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/devices/local_device_material.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  setUp(() async {
    resetDeviceLinkChallengesForTests();
    await setVaultKek(List<int>.generate(32, (i) => (i * 5 + 3) & 0xff));
  });
  tearDown(clearVaultKek);

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
        localIdentityPublicKey: spki,
      ),
      isTrue,
    );
    expect(
      await acceptDeviceLink(
        link,
        ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        registry: registry,
        localIdentityPublicKey: spki,
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
        localIdentityPublicKey: spki,
      ),
      isFalse,
    );
  });

  test('acceptDeviceLink notifies DualStack without minting a ratchet', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final material = await loadOrCreateLocalDeviceMaterial(store: InMemoryKeyStore());
    final link = await issueLocalDeviceLink(
      material: material,
      ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    final registry = DeviceRegistry();
    AuthorizedDevice? authorized;
    expect(
      await acceptDeviceLink(
        link,
        ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        registry: registry,
        localIdentityPublicKey: spki,
        onAuthorized: (device) => authorized = device,
      ),
      isTrue,
    );
    expect(authorized?.deviceId, material.deviceId);
    expect(registry.byId(material.deviceId), isNotNull);
    expect(jsonEncode(link.toQrJson()).toLowerCase().contains('rootkey'), isFalse);
  });

  test('attacker-signed QR with victim ownerPeerId is rejected', () async {
    final victim = await generateP256EcdsaKey();
    final victimSpki = buildP256Spki(x: victim.x, y: victim.y);
    final attacker = await generateP256EcdsaKey();
    final attackerSpki = buildP256Spki(x: attacker.x, y: attacker.y);
    final material =
        await loadOrCreateLocalDeviceMaterial(store: InMemoryKeyStore());
    final link = await issueLocalDeviceLink(
      material: material,
      ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      identityPublicKey: attackerSpki,
      sign: (payload) async => signP256Ecdsa(attacker, payload),
    );
    final identities = TrustedIdentityStore()
      ..trust(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        identityPublicKey: victimSpki,
        isSelf: true,
      );
    final registry = DeviceRegistry();
    expect(
      await acceptDeviceLink(
        link,
        ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        registry: registry,
        identities: identities,
      ),
      isFalse,
    );
    expect(registry.byId(material.deviceId), isNull);
  });

  test('empty ownerPeerId on QR is rejected', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final link = await issueDeviceLink(
      deviceId: 'phone-2',
      transportPublicKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 3)),
      hypercorePublicKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 4)),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    expect(
      await acceptDeviceLink(
        link,
        ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        localIdentityPublicKey: spki,
        registry: DeviceRegistry(),
      ),
      isFalse,
    );
  });

  test('self-link accepts only the local/trusted identity', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final material =
        await loadOrCreateLocalDeviceMaterial(store: InMemoryKeyStore());
    final link = await issueLocalDeviceLink(
      material: material,
      ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    final identities = TrustedIdentityStore()
      ..trust(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        identityPublicKey: spki,
        isSelf: true,
      );
    expect(
      await acceptDeviceLink(
        link,
        ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        identities: identities,
        registry: DeviceRegistry(),
      ),
      isTrue,
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

  test('DeviceLinkPage calls DualStack authorize and revoke', () {
    final src = File('lib/ui/profile/device_link_page.dart').readAsStringSync();
    expect(src, contains('nativeBridge'));
    expect(src, contains('authorizeDevice'));
    expect(src, contains('revokeDevice'));
    expect(src, contains('onAuthorized:'));
    expect(src.toLowerCase(), isNot(contains('rootkey')));
  });
}
