import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/devices/device_link.dart';
import 'package:orbits_flutter/devices/device_registry.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  test(
    'expired, forged, duplicate, and revoked bindings are rejected',
    () async {
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
      expect(await verifyDeviceLink(link), isTrue);

      final forged = DeviceLinkPayload(
        deviceId: link.deviceId,
        transportPublicKey: link.transportPublicKey,
        hypercorePublicKey: link.hypercorePublicKey,
        createdAt: link.createdAt,
        signature: Uint8List.fromList(List<int>.filled(64, 1)),
        identityPublicKey: spki,
      );
      expect(await verifyDeviceLink(forged), isFalse);

      final registry = DeviceRegistry();
      registry.authorize(
        AuthorizedDevice(
          deviceId: 'phone-2',
          transportPublicKey: List<int>.filled(32, 7),
          hypercorePublicKey: List<int>.filled(32, 8),
          name: 'phone-2',
          kind: 'phone',
          createdAt: 1,
          status: DeviceStatus.active,
        ),
      );
      registry.revoke('phone-2');
      expect(registry.acceptsWriter('phone-2'), isFalse);
      expect(
        () => registry.authorize(
          AuthorizedDevice(
            deviceId: 'phone-2',
            transportPublicKey: List<int>.filled(32, 7),
            hypercorePublicKey: List<int>.filled(32, 8),
            name: 'phone-2',
            kind: 'phone',
            createdAt: 2,
            status: DeviceStatus.active,
          ),
        ),
        throwsStateError,
      );
    },
  );

  test('authorization log projection is deterministic after restart', () {
    final first = DeviceRegistry();
    first.authorize(
      AuthorizedDevice(
        deviceId: 'a',
        transportPublicKey: List<int>.filled(32, 1),
        hypercorePublicKey: List<int>.filled(32, 2),
        name: 'a',
        kind: 'phone',
        createdAt: 1,
        status: DeviceStatus.active,
      ),
    );
    first.revoke('a');
    first.authorize(
      AuthorizedDevice(
        deviceId: 'b',
        transportPublicKey: List<int>.filled(32, 3),
        hypercorePublicKey: List<int>.filled(32, 4),
        name: 'b',
        kind: 'tablet',
        createdAt: 2,
        status: DeviceStatus.active,
      ),
    );
    final snap = first.toJson();
    final second = DeviceRegistry();
    second.replaceAll([
      for (final item in snap['devices'] as List)
        AuthorizedDevice.fromJson(Map<String, Object?>.from(item as Map)),
    ]);
    expect(second.acceptsWriter('a'), first.acceptsWriter('a'));
    expect(second.acceptsWriter('b'), first.acceptsWriter('b'));
    expect(second.toJson()['devices'], first.toJson()['devices']);
  });
}
