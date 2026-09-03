import 'dart:typed_data';

import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/transport/device_binding.dart';

import 'pointycastle_ecdh.dart';

/// Real P-256 identity signature over a device binding for tests.
Future<DeviceBinding> signedDeviceBinding({
  required String peerId,
  required String deviceId,
  List<int>? transportPublicKey,
  List<int>? hypercorePublicKey,
  List<String> capabilities = const ['hyperswarm-v1'],
  int? createdAt,
  int? expiresAt,
}) async {
  final pair = await generateP256EcdsaKey();
  final identity = buildP256Spki(x: pair.x, y: pair.y);
  final now = createdAt ?? DateTime.now().millisecondsSinceEpoch;
  final draft = DeviceBinding(
    version: kDeviceBindingVersion,
    identityPublicKey: identity,
    deviceId: deviceId,
    transportPublicKey: Uint8List.fromList(
      transportPublicKey ?? List<int>.generate(32, (i) => i + 1),
    ),
    hypercorePublicKey: Uint8List.fromList(
      hypercorePublicKey ?? List<int>.generate(32, (i) => i + 2),
    ),
    capabilities: capabilities,
    createdAt: now,
    expiresAt: expiresAt ?? now + 60 * 60 * 1000,
    signatureByIdentityKey: Uint8List(0),
    ownerPeerId: peerId,
  );
  return DeviceBinding(
    version: draft.version,
    identityPublicKey: draft.identityPublicKey,
    deviceId: draft.deviceId,
    transportPublicKey: draft.transportPublicKey,
    hypercorePublicKey: draft.hypercorePublicKey,
    capabilities: draft.capabilities,
    createdAt: draft.createdAt,
    expiresAt: draft.expiresAt,
    signatureByIdentityKey: signP256Ecdsa(pair, draft.signedPayload()),
    ownerPeerId: draft.ownerPeerId,
  );
}
