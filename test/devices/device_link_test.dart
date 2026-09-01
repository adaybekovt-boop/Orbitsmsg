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
  });
}
