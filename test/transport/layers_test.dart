import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/peer/room_disclaimer.dart';
import 'package:orbits_flutter/push/push_gateway.dart';
import 'package:orbits_flutter/replication/corestore_addon.dart';
import 'package:orbits_flutter/transport/bare_runtime.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/fleet_status.dart';
import 'package:orbits_flutter/transport/layers.dart';
import 'package:orbits_flutter/transport/peerjs_window.dart';
import 'package:orbits_flutter/transport/relay_directory.dart';
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
    expect(peerjsIsProductPath(), isTrue);
    expect(kLiveSignedRelayDirectory, isFalse);
    expect(kLiveStorageFleet, isFalse);
    expect(kLiveApnsGateway, isFalse);
    expect(kLiveFcmGateway, isFalse);
    expect(kBareBinaryShipped, isFalse);
    expect(kBareWorkletRunsOnBareRuntime, isTrue);
    expect(
      File('tool/connectivity_harness/src/worklet.js').readAsStringSync(),
      contains("require('node:fs')"),
    );
    expect(
      File('tool/connectivity_harness/src/worklet.js').readAsStringSync(),
      contains("require('bare-process')"),
    );
    expect(
      File('tool/connectivity_harness/package.json').readAsStringSync(),
      contains('"bare": "bare-fs"'),
    );
    final worklet = File('tool/connectivity_harness/src/worklet.js').readAsStringSync();
    expect(worklet, contains('function hashPath'));
    expect(worklet, contains('hashPath(file.path)'));
    expect(worklet, contains('fs.openSync(file.path'));
    expect(worklet, contains('fs.readSync'));
    expect(worklet, contains('sendFile takes a path, not bytes'));
    expect(worklet, contains('resumeOffset'));
    expect(worklet, contains('harness-file-resume'));
    expect(worklet, contains('fs.writeSync'));
    expect(worklet, contains('file-send interrupted'));
    expect(worklet, contains('relayThrough'));
    expect(worklet, contains('localJournalDir'));
    expect(worklet, contains('journalDir'));
    expect(worklet, contains('journalBackend'));
    expect(worklet, isNot(contains('readFileSync(file.path)')));
    expect(worklet, isNot(contains('http://')));
    expect(worklet, isNot(contains('https://')));
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains("'path': file.path"),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains("'resumeOffset': file.resumeOffset"),
    );
    expect(kHolepunchCorestoreAddonLinked, isFalse);
    expect(kCorestoreJsModuleOptional, isTrue);
    expect(
      File('lib/transport/loopback_transport.dart').readAsStringSync(),
      contains('IncomingPathAttachment'),
    );
    expect(
      File('lib/transport/loopback_transport.dart').readAsStringSync(),
      isNot(contains('incoming.bytes.addAll')),
    );
    expect(
      File('lib/attachments/path_attachment.dart').existsSync(),
      isTrue,
    );
    expect(
      File('lib/core/orbits_drop.dart').readAsStringSync(),
      contains('sendFileRanged'),
    );
    expect(
      File('lib/core/orbits_drop.dart').readAsStringSync(),
      contains('openIncomingStore'),
    );
    expect(
      File('lib/attachments/path_drop_store.dart').existsSync(),
      isTrue,
    );
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
    expect(replicationFieldsAreSafe(['fileKey']), isFalse);
    expect(replicationFieldsAreSafe(['attachmentBytes']), isFalse);
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
