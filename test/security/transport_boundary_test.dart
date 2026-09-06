import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/incoming_paths.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/replication/conversation_id.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';

import '../helpers/signed_device_binding.dart';

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  test('unauthenticated peer cannot file, replicate, or appear connected', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
    final secret = List<int>.generate(32, (i) => 5);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()..put(alice, secret)..put(bob, secret);
    final bindA = await signedDeviceBinding(peerId: alice, deviceId: 'a');
    await pair.$1.start(
      TransportLocalConfiguration(peerId: alice, discoverySecret: secret),
    );
    await pair.$2.start(
      TransportLocalConfiguration(peerId: bob, discoverySecret: secret),
    );
    final bindB = await signedDeviceBinding(peerId: bob, deviceId: 'b');
    await pair.$1.publish(bindA);
    await pair.$2.publish(bindB);
    final incoming = Directory.systemTemp.createTempSync('orbits-sec-');
    addTearDown(() {
      if (incoming.existsSync()) incoming.deleteSync(recursive: true);
    });
    final aliceIds = TrustedIdentityStore();
    final aliceDev = DeviceRegistry();
    trustBinding(
      identities: aliceIds,
      devices: aliceDev,
      binding: bindA,
      isSelf: true,
    );
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => alice,
      selfDeviceId: 'a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    a.files.incomingBase = incoming;
    await pair.$2.connect(const PeerDescriptor(peerId: alice));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(a.isAuthenticated(bob), isFalse);
    expect(a.isNativeConnected(bob), isFalse);
    try {
      await pair.$2.send(
        alice,
        TransportChannel.attachment,
        jsonPayload({
          'type': 'file-offer',
          'protocol': 'orbits-file-v1',
          'transferId': 'evil-id',
          'name': 'x',
          'size': 1,
          'sha256': '00',
        }),
      );
      await pair.$2.send(
        alice,
        TransportChannel.replication,
        jsonPayload({
          'type': 'repl-event',
          'info': kReplicationEventInfo,
          'kind': ReplicationEventKind.messageEnvelopeCreated.name,
          'seq': 1,
          'writerDeviceId': 'forger',
          'fields': {
            'conversationId': conversationIdForPeers(alice, bob),
            'encryptedEnvelope': base64Encode(utf8.encode('NO')),
          },
        }),
      );
    } catch (_) {
      // Fail-closed: unauthenticated send is rejected by the carrier.
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(a.isAuthenticated(bob), isFalse);
    expect(a.isNativeConnected(bob), isFalse);
    expect(
      incomingRoot(incoming).existsSync()
          ? incomingRoot(incoming).listSync()
          : const [],
      isEmpty,
    );
    expect(a.hypercore.blocks, isEmpty);
  });

  test('stolen ownerPeerId binding never authenticates', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
    final secret = List<int>.generate(32, (i) => 6);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()..put(alice, secret)..put(bob, secret);
    final bindA = await signedDeviceBinding(peerId: alice, deviceId: 'a');
    final stolen = await signedDeviceBinding(
      peerId: alice,
      deviceId: 'stolen',
    );
    await pair.$1.start(
      TransportLocalConfiguration(peerId: alice, discoverySecret: secret),
    );
    await pair.$2.start(
      TransportLocalConfiguration(peerId: bob, discoverySecret: secret),
    );
    await pair.$1.publish(bindA);
    await pair.$2.publish(stolen);
    final aliceIds = TrustedIdentityStore();
    final aliceDev = DeviceRegistry();
    trustBinding(
      identities: aliceIds,
      devices: aliceDev,
      binding: bindA,
      isSelf: true,
    );
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => alice,
      selfDeviceId: 'a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    await pair.$2.connect(const PeerDescriptor(peerId: alice));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(a.isAuthenticated(bob), isFalse);
    expect(a.isAuthenticated(alice), isFalse);
  });
}
