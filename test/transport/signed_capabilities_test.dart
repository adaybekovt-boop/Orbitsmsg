import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/transport/capabilities.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/hello_capabilities.dart';
import 'package:orbits_flutter/transport/signed_capabilities.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  test('capability payload is canonical and sorts wire names', () {
    final record = CapabilityRecord(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-1',
      capabilities: {
        TransportCapability.hyperswarmV1,
        TransportCapability.peerjsV4,
      },
      issuedAt: 1,
      expiresAt: 2,
      signature: Uint8List(0),
      identityPublicKey: Uint8List.fromList(const [1]),
    );
    final text = utf8.decode(record.signedPayload());
    expect(text, startsWith('orbits-capabilities-v1\n'));
    expect(text, contains('hyperswarm-v1,peerjs-v4'));
    expect(record.signedPayload(), record.signedPayload());
  });

  test('identity key signs capabilities; Noise key is not used', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final record = await issueCapabilityRecord(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-1',
      capabilities: {
        TransportCapability.hyperswarmV1,
        TransportCapability.peerjsV4,
      },
      issuedAt: 1,
      expiresAt: 10,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    expect(await verifyCapabilityRecord(record), isTrue);
    expect(record.toWire()['capabilities'], ['hyperswarm-v1', 'peerjs-v4']);
    final again = CapabilityRecord.fromWire(record.toWire());
    expect(await verifyCapabilityRecord(again), isTrue);
    expect(
      logDowngrade(
        selected: TransportRoute.peerjs,
        preferHyperswarm: true,
        localIsPwa: true,
        remoteIsPwa: false,
      )?.reason,
      'pwa',
    );
  });

  test('PeerJS hello caps are verified separately from the hello blob', () async {
    remoteCapabilityCache.clear();
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final record = await issueCapabilityRecord(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-1',
      capabilities: {
        TransportCapability.hyperswarmV1,
        TransportCapability.peerjsV4,
      },
      issuedAt: 1,
      expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    final remembered = await rememberHelloCapabilities(
      'ORBIT-AAAAAAAAAAAAAAAA',
      {
        'type': 'wireHello',
        'v': 3,
        'caps': record.toWire(),
      },
    );
    expect(remembered, isNotNull);
    expect(
      remoteCapabilityCache.get('orbit-aaaaaaaaaaaaaaaa')?.deviceId,
      'dev-1',
    );
    await rememberHelloCapabilities('ORBIT-BBBBBBBBBBBBBBBB', {
      'type': 'wireHello',
      'v': 3,
      'caps': record.toWire(),
    });
    expect(remoteCapabilityCache.get('ORBIT-BBBBBBBBBBBBBBBB'), isNull);
  });

  test('identity key signs device binding; Noise is not used', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final names = advertisedLocalCapabilityWireNames();
    expect(names, contains('mailbox-v1'));
    expect(names, contains('hypercore-v1'));
    expect(names, contains('multi-device-v1'));
    expect(names, contains('peerjs-v4'));
    expect(names, contains('hyperswarm-v1'));
    expect(names, isNot(contains('://')));

    final binding = await issueDeviceBinding(
      identityPublicKey: spki,
      deviceId: 'local-device',
      transportPublicKey:
          Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
      hypercorePublicKey:
          Uint8List.fromList(List<int>.generate(32, (i) => i + 2)),
      capabilities: names,
      createdAt: 1,
      expiresAt: 10,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    expect(await verifyDeviceBinding(binding), isTrue);
    expect(binding.capabilities, names);
    expect(
      binding.signatureByIdentityKey,
      isNot(equals(Uint8List(0))),
    );

    final capRecord = await issueCapabilityRecord(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'local-device',
      capabilities: advertisedLocalCapabilities(),
      issuedAt: 1,
      expiresAt: 10,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    expect(
      binding.signatureByIdentityKey,
      isNot(equals(capRecord.signature)),
    );

    final tampered = DeviceBinding(
      version: binding.version,
      identityPublicKey: binding.identityPublicKey,
      deviceId: binding.deviceId,
      transportPublicKey: binding.transportPublicKey,
      hypercorePublicKey: binding.hypercorePublicKey,
      capabilities: const ['hyperswarm-v1', 'peerjs-v4'],
      createdAt: binding.createdAt,
      expiresAt: binding.expiresAt,
      signatureByIdentityKey: binding.signatureByIdentityKey,
    );
    expect(await verifyDeviceBinding(tampered), isFalse);
    await expectLater(
      issueDeviceBinding(
        identityPublicKey: spki,
        deviceId: 'local-device',
        transportPublicKey: Uint8List.fromList(const [1]),
        hypercorePublicKey: Uint8List.fromList(const [2]),
        capabilities: const ['https://evil.example/cap'],
        createdAt: 1,
        expiresAt: 10,
        sign: (payload) async => signP256Ecdsa(pair, payload),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}
