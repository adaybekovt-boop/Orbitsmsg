import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';

import 'pointycastle_ecdh.dart';

class SignedIdentity {
  SignedIdentity({
    required this.peerId,
    required this.pair,
    required this.spki,
  });

  final String peerId;
  final EcKeyPairData pair;
  final Uint8List spki;
}

Future<SignedIdentity> signedIdentity(String peerId) async {
  final pair = await generateP256EcdsaKey();
  return SignedIdentity(
    peerId: peerId,
    pair: pair,
    spki: buildP256Spki(x: pair.x, y: pair.y),
  );
}

/// Real P-256 identity signature over a device binding for tests.
Future<DeviceBinding> signedDeviceBinding({
  required String peerId,
  required String deviceId,
  List<int>? transportPublicKey,
  List<int>? hypercorePublicKey,
  List<String> capabilities = const ['hyperswarm-v1'],
  int? createdAt,
  int? expiresAt,
  SignedIdentity? identity,
}) async {
  final signed = identity ?? await signedIdentity(peerId);
  final now = createdAt ?? DateTime.now().millisecondsSinceEpoch;
  final draft = DeviceBinding(
    version: kDeviceBindingVersion,
    identityPublicKey: signed.spki,
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
    signatureByIdentityKey: signP256Ecdsa(signed.pair, draft.signedPayload()),
    ownerPeerId: draft.ownerPeerId,
  );
}

void trustBinding({
  required TrustedIdentityStore identities,
  required DeviceRegistry devices,
  required DeviceBinding binding,
  bool isSelf = false,
  String? transportPeerId,
}) {
  identities.trust(
    peerId: binding.ownerPeerId,
    identityPublicKey: binding.identityPublicKey,
    isSelf: isSelf,
  );
  devices.authorize(
    AuthorizedDevice(
      deviceId: binding.deviceId,
      transportPublicKey: binding.transportPublicKey,
      hypercorePublicKey: binding.hypercorePublicKey,
      name: binding.deviceId,
      kind: isSelf ? 'own' : 'contact',
      createdAt: binding.createdAt,
      status: DeviceStatus.active,
      ownerPeerId: binding.ownerPeerId,
      transportPeerId: transportPeerId ?? binding.ownerPeerId,
    ),
  );
}

void trustContactPair({
  required TrustedIdentityStore aliceIdentities,
  required DeviceRegistry aliceDevices,
  required TrustedIdentityStore bobIdentities,
  required DeviceRegistry bobDevices,
  required DeviceBinding aliceBinding,
  required DeviceBinding bobBinding,
}) {
  trustBinding(
    identities: aliceIdentities,
    devices: aliceDevices,
    binding: aliceBinding,
    isSelf: true,
  );
  trustBinding(
    identities: aliceIdentities,
    devices: aliceDevices,
    binding: bobBinding,
  );
  trustBinding(
    identities: bobIdentities,
    devices: bobDevices,
    binding: bobBinding,
    isSelf: true,
  );
  trustBinding(
    identities: bobIdentities,
    devices: bobDevices,
    binding: aliceBinding,
  );
}
