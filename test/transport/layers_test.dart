import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/peer/room_disclaimer.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/layers.dart';
import 'package:orbits_flutter/transport/peerjs_window.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  test('Phase 0 is the completed phase and Hyperswarm stays off', () {
    expect(kCompletedMigrationPhase, 0);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(isHyperswarmTransportEnabled(), isFalse);
    expect(isPeerjsFallbackEnabled(), isTrue);
    expect(kRoomsApplicationE2eImplemented, isFalse);
    expect(kPeerjsSupportWindowOpen, isTrue);
    expect(kPeerjsIsolationMode, 'default-live');
  });

  test('connect checks keep block before TOFU', () {
    expect(requiredBindingChecks(), kConnectBindingChecks);
    expect(
      kConnectBindingChecks.indexOf('contactNotBlocked'),
      lessThan(kConnectBindingChecks.indexOf('tofuDoesNotConflict')),
    );
  });

  test('journal fields reject secrets', () {
    expect(replicationFieldsAreSafe(['eventId', 'encryptedEnvelope']), isTrue);
    expect(replicationFieldsAreSafe(['encryptedEnvelope', 'rootKey']), isFalse);
    expect(replicationFieldsAreSafe(['vaultKek']), isFalse);
    expect(replicationFieldsAreSafe(['plaintext']), isFalse);
  });

  test('MessageEnvelopeCreated only exposes allowed journal keys', () {
    const event = MessageEnvelopeCreated(
      eventId: 'e1',
      conversationId: 'c1',
      senderIdentity: 'id',
      senderDeviceId: 'dev',
      logicalSequence: 1,
      createdAt: 1,
      encryptedEnvelope: <int>[1, 2, 3],
    );
    expect(event.isSafeForHypercore, isTrue);
    expect(event.toJournalFields().containsKey('plaintext'), isFalse);
  });

  test('noise key compare is exact', () {
    final binding = DeviceBinding(
      version: kDeviceBindingVersion,
      identityPublicKey: Uint8List.fromList(const [1]),
      deviceId: 'd1',
      transportPublicKey: Uint8List.fromList(const [9, 8, 7]),
      hypercorePublicKey: Uint8List.fromList(const [2]),
      capabilities: const ['peerjs-v4'],
      createdAt: 1,
      expiresAt: 2,
      signatureByIdentityKey: Uint8List.fromList(const [3]),
    );
    expect(
      noiseKeyMatchesBinding(
        connectionNoisePublicKey: const [9, 8, 7],
        binding: binding,
      ),
      isTrue,
    );
    expect(
      noiseKeyMatchesBinding(
        connectionNoisePublicKey: const [9, 8, 0],
        binding: binding,
      ),
      isFalse,
    );
  });

  test('binding payload is length-prefixed and deterministic', () {
    final binding = DeviceBinding(
      version: kDeviceBindingVersion,
      identityPublicKey: Uint8List.fromList(const [1, 2]),
      deviceId: 'dev-1',
      transportPublicKey: Uint8List.fromList(const [3]),
      hypercorePublicKey: Uint8List.fromList(const [4]),
      capabilities: const ['peerjs-v4', 'hyperswarm-v1'],
      createdAt: 100,
      expiresAt: 200,
      signatureByIdentityKey: Uint8List.fromList(const [5]),
    );
    final payload = binding.signedPayload();
    expect(payload, binding.signedPayload());
    expect(payload.take(4), [0, 0, 0, 1]);
    expect(payload, isNot(equals(binding.signatureByIdentityKey)));
  });
}
