import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/peer_pins.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/transport/connect_binding.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/layers.dart';
import 'package:orbits_flutter/transport/signed_capabilities.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  test('connect checks keep ADR-0001 order', () {
    expect(
      kConnectBindingChecks,
      [
        'noiseMatchesBinding',
        'signedByKnownIdentity',
        'deviceNotRevoked',
        'protocolCompatible',
        'contactNotBlocked',
        'tofuDoesNotConflict',
      ],
    );
  });

  test('evaluateConnectBindingChecks fails in lock order', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final transport = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    final binding = await issueDeviceBinding(
      identityPublicKey: spki,
      deviceId: 'dev-1',
      transportPublicKey: transport,
      hypercorePublicKey:
          Uint8List.fromList(List<int>.generate(32, (i) => i + 2)),
      capabilities: const ['hyperswarm-v1', 'peerjs-v4'],
      createdAt: 1,
      expiresAt: 10,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );

    expect(
      (await evaluateConnectBindingChecks(
        binding: DeviceBinding(
          version: binding.version,
          identityPublicKey: binding.identityPublicKey,
          deviceId: binding.deviceId,
          transportPublicKey: Uint8List(0),
          hypercorePublicKey: binding.hypercorePublicKey,
          capabilities: binding.capabilities,
          createdAt: binding.createdAt,
          expiresAt: binding.expiresAt,
          signatureByIdentityKey: binding.signatureByIdentityKey,
        ),
        contactBlocked: true,
      ))
          .failedCheck,
      'noiseMatchesBinding',
    );

    expect(
      (await evaluateConnectBindingChecks(
        binding: binding,
        connectionNoisePublicKey: List<int>.generate(32, (i) => 9),
      ))
          .failedCheck,
      'noiseMatchesBinding',
    );

    final unsigned = DeviceBinding(
      version: binding.version,
      identityPublicKey: binding.identityPublicKey,
      deviceId: binding.deviceId,
      transportPublicKey: binding.transportPublicKey,
      hypercorePublicKey: binding.hypercorePublicKey,
      capabilities: binding.capabilities,
      createdAt: binding.createdAt,
      expiresAt: binding.expiresAt,
      signatureByIdentityKey: Uint8List.fromList(const [1]),
    );
    expect(
      (await evaluateConnectBindingChecks(
        binding: unsigned,
        deviceRevoked: true,
        contactBlocked: true,
      ))
          .failedCheck,
      'signedByKnownIdentity',
    );

    expect(
      (await evaluateConnectBindingChecks(
        binding: binding,
        deviceRevoked: true,
        contactBlocked: true,
      ))
          .failedCheck,
      'deviceNotRevoked',
    );

    expect(
      (await evaluateConnectBindingChecks(
        binding: binding,
        protocolVersion: 99,
        contactBlocked: true,
      ))
          .failedCheck,
      'protocolCompatible',
    );

    expect(
      (await evaluateConnectBindingChecks(
        binding: binding,
        contactBlocked: true,
        tofu: const PinCheck(
          status: PinStatus.mismatch,
          fingerprint: 'x',
        ),
      ))
          .failedCheck,
      'contactNotBlocked',
    );

    expect(
      (await evaluateConnectBindingChecks(
        binding: binding,
        tofu: const PinCheck(
          status: PinStatus.mismatch,
          fingerprint: 'x',
          expected: 'y',
        ),
      ))
          .failedCheck,
      'tofuDoesNotConflict',
    );

    expect(
      (await evaluateConnectBindingChecks(
        binding: binding,
        connectionNoisePublicKey: transport,
        tofu: const PinCheck(status: PinStatus.newPin, fingerprint: 'ok'),
      ))
          .ok,
      isTrue,
    );

    final wire = binding.toWire();
    expect(wire.containsKey('fileKey'), isFalse);
    expect(wire.containsKey('rootKey'), isFalse);
    final roundTrip = DeviceBinding.fromWire(wire);
    expect(await verifyDeviceBinding(roundTrip), isTrue);
    expect(roundTrip.deviceId, binding.deviceId);
    expect(
      () => DeviceBinding.fromWire({
        ...wire,
        'fileKey': 'nope',
      }),
      throwsArgumentError,
    );
  });
}
