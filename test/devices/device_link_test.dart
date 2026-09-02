import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/devices/device_link.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  test('QR device-link payload is signed by the identity key', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final link = await issueDeviceLink(
      deviceId: 'phone-2',
      transportPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
      hypercorePublicKey: Uint8List.fromList(List<int>.filled(32, 8)),
      createdAt: 1,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    final again = DeviceLinkPayload.fromQrJson(link.toQrJson());
    expect(again.deviceId, 'phone-2');
    expect(again.signature, link.signature);
    expect(again.signedPayload(), link.signedPayload());
    expect(again.identityPublicKey, spki);
    expect(link.toQrJson()['v'], kDeviceLinkInfo);
    expect(await verifyDeviceLink(link), isTrue);
    expect(
      await verifyDeviceLink(
        DeviceLinkPayload(
          deviceId: link.deviceId,
          transportPublicKey: link.transportPublicKey,
          hypercorePublicKey: link.hypercorePublicKey,
          createdAt: link.createdAt,
          signature: Uint8List.fromList(List<int>.filled(64, 9)),
          identityPublicKey: spki,
        ),
      ),
      isFalse,
    );
    // Noise / Hypercore writer keys are not the identity key.
    expect(link.transportPublicKey, isNot(equals(spki)));
    expect(link.hypercorePublicKey, isNot(equals(spki)));
    expect(link.identityPublicKey, spki);
  });

  test('honest toQrJson still fromQrJson and verifyDeviceLink', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final link = await issueDeviceLink(
      deviceId: 'phone-honest',
      transportPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
      hypercorePublicKey: Uint8List.fromList(List<int>.filled(32, 8)),
      createdAt: 1,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    final json = link.toQrJson();
    expect(json.containsKey('fileKey'), isFalse);
    expect(json.containsKey('opaqueWakeToken'), isFalse);
    expect(json.containsKey('deviceId'), isTrue);
    expect(json.keys, isNot(contains(contains('://'))));

    final again = DeviceLinkPayload.fromQrJson(json);
    expect(again.deviceId, 'phone-honest');
    expect(again.signature, link.signature);
    expect(again.signedPayload(), link.signedPayload());
    expect(again.identityPublicKey, spki);
    expect(await verifyDeviceLink(again), isTrue);
  });

  test('DeviceLinkPayload.fromQrJson refuses nested secret fields', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final link = await issueDeviceLink(
      deviceId: 'phone-refuse',
      transportPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
      hypercorePublicKey: Uint8List.fromList(List<int>.filled(32, 8)),
      createdAt: 1,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    final json = link.toQrJson();

    expect(
      () => DeviceLinkPayload.fromQrJson({
        ...json,
        'extra': {'fileKey': 'x'},
      }),
      throwsArgumentError,
    );
    expect(
      () => DeviceLinkPayload.fromQrJson({
        ...json,
        'opaqueWakeToken': 'tok',
      }),
      throwsArgumentError,
    );
    expect(
      () => DeviceLinkPayload.fromQrJson({
        ...json,
        'extra': {'https://evil': 'x'},
      }),
      throwsArgumentError,
    );
  });

  test('fromQrJson refuses URL-shaped deviceId value', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final link = await issueDeviceLink(
      deviceId: 'phone-2',
      transportPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
      hypercorePublicKey: Uint8List.fromList(List<int>.filled(32, 8)),
      createdAt: 1,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    expect(
      () => DeviceLinkPayload.fromQrJson({
        ...link.toQrJson(),
        'deviceId': 'https://evil',
      }),
      throwsArgumentError,
    );
  });

  test('fromQrJson refuses empty deviceId value', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final link = await issueDeviceLink(
      deviceId: 'phone-2',
      transportPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
      hypercorePublicKey: Uint8List.fromList(List<int>.filled(32, 8)),
      createdAt: 1,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    expect(
      () => DeviceLinkPayload.fromQrJson({
        ...link.toQrJson(),
        'deviceId': '',
      }),
      throwsArgumentError,
    );
  });

  test('issueDeviceLink refuses URL-shaped deviceId', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    var signed = false;
    await expectLater(
      issueDeviceLink(
        deviceId: 'https://evil',
        transportPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
        hypercorePublicKey: Uint8List.fromList(List<int>.filled(32, 8)),
        createdAt: 1,
        identityPublicKey: spki,
        sign: (payload) async {
          signed = true;
          return signP256Ecdsa(pair, payload);
        },
      ),
      throwsArgumentError,
    );
    expect(signed, isFalse);
  });

  test('verifyDeviceLink is false for constructed :// deviceId', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final honest = await issueDeviceLink(
      deviceId: 'phone-2',
      transportPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
      hypercorePublicKey: Uint8List.fromList(List<int>.filled(32, 8)),
      createdAt: 1,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    final constructed = DeviceLinkPayload(
      deviceId: 'https://evil',
      transportPublicKey: honest.transportPublicKey,
      hypercorePublicKey: honest.hypercorePublicKey,
      createdAt: honest.createdAt,
      signature: honest.signature,
      identityPublicKey: honest.identityPublicKey,
    );
    expect(await verifyDeviceLink(constructed), isFalse);
  });
}
