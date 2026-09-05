import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/peer/helpers.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/replication/replication_authorization.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';

import '../helpers/signed_device_binding.dart';

const aliceId = 'ORBIT-AAAAAAAAAAAAAAAA';
const bobId = 'ORBIT-BBBBBBBBBBBBBBBB';
const carolId = 'ORBIT-CCCCCCCCCCCCCCCC';

JournalRecord _envelope({
  required String conversationId,
  required List<int> ciphertext,
  String sender = aliceId,
}) {
  return JournalRecord(
    seq: 0,
    writerDeviceId: 'dev-alice',
    kind: ReplicationEventKind.messageEnvelopeCreated,
    fields: <String, Object?>{
      'conversationId': conversationId,
      'senderIdentity': sender,
      'senderDeviceId': 'dev-alice',
      'encryptedEnvelope': ciphertext,
      'createdAt': 1,
    },
  );
}

JournalRecord _deviceEvent(ReplicationEventKind kind, String deviceId) {
  return JournalRecord(
    seq: 0,
    writerDeviceId: 'dev-alice',
    kind: kind,
    fields: <String, Object?>{
      'deviceId': deviceId,
      'ownerPeerId': aliceId,
      'audience': 'owner-devices',
      'createdAt': 1,
    },
  );
}

bool _wireMentionsCarol(List<int> bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  if (text.contains(carolId) || text.contains(normalizePeerId(carolId))) {
    return true;
  }
  if (text.contains('CAROL-SECRET') || text.contains('alice-phone-2')) {
    return true;
  }
  final carolB64 = base64Encode(utf8.encode('CAROL-SECRET'));
  return text.contains(carolB64);
}

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  test('F-20: Bob never receives Carol conversation or device records', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final secret = List<int>.generate(32, (i) => 11);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put(aliceId, secret)
      ..put(bobId, secret);
    final bindA = await signedDeviceBinding(peerId: aliceId, deviceId: 'dev-alice');
    final bindB = await signedDeviceBinding(peerId: bobId, deviceId: 'dev-bob');

    await pair.$1.start(
      TransportLocalConfiguration(peerId: aliceId, discoverySecret: secret),
    );
    await pair.$2.start(
      TransportLocalConfiguration(peerId: bobId, discoverySecret: secret),
    );
    await pair.$1.publish(bindA);
    await pair.$2.publish(bindB);

    final aliceIds = TrustedIdentityStore();
    final bobIds = TrustedIdentityStore();
    final aliceDev = DeviceRegistry();
    final bobDev = DeviceRegistry();
    trustContactPair(
      aliceIdentities: aliceIds,
      aliceDevices: aliceDev,
      bobIdentities: bobIds,
      bobDevices: bobDev,
      aliceBinding: bindA,
      bobBinding: bindB,
    );
    final alice = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('dev-alice'),
      selfPeerId: () => aliceId,
      selfDeviceId: 'dev-alice',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    final bob = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('dev-bob'),
      selfPeerId: () => bobId,
      selfDeviceId: 'dev-bob',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();

    final bobWire = <List<int>>[];
    final bobSub = pair.$2.events.listen((event) {
      if (event is TransportFrame && event.channel == TransportChannel.replication) {
        bobWire.add(event.bytes);
      }
    });

    alice.hypercore.append(
      _envelope(conversationId: bobId, ciphertext: utf8.encode('BOB-ONLY')),
    );
    alice.hypercore.append(
      _envelope(conversationId: carolId, ciphertext: utf8.encode('CAROL-SECRET')),
    );
    alice.hypercore.append(_deviceEvent(ReplicationEventKind.deviceAuthorized, 'alice-phone-2'));

    await pair.$1.connect(PeerDescriptor(peerId: bobId, discoverySecret: secret));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(alice.isAuthenticated(bobId), isTrue);

    expect(bobWire, isNotEmpty);
    for (final frame in bobWire) {
      expect(_wireMentionsCarol(frame), isFalse, reason: utf8.decode(frame));
    }
    expect(
      bob.hypercore.blocks.any((r) {
        final cid = normalizedConversationId(r.fields);
        return cid == normalizePeerId(carolId);
      }),
      isFalse,
    );
    expect(
      bob.hypercore.blocks.any((r) => isOwnerDeviceScopedKind(r.kind)),
      isFalse,
    );

    final afterReplay = bobWire.length;
    alice.appendAndReplicate(
      _envelope(conversationId: carolId, ciphertext: utf8.encode('CAROL-SECRET')),
    );
    alice.appendAndReplicate(
      _deviceEvent(ReplicationEventKind.deviceRevoked, 'alice-phone-2'),
    );
    alice.appendAndReplicate(
      _envelope(conversationId: bobId, ciphertext: utf8.encode('BOB-LIVE')),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    final live = bobWire.skip(afterReplay).toList();
    for (final frame in live) {
      expect(_wireMentionsCarol(frame), isFalse, reason: utf8.decode(frame));
    }
    expect(
      live.any((f) => utf8.decode(f).contains(base64Encode(utf8.encode('BOB-LIVE')))),
      isTrue,
    );

    await bobSub.cancel();
    await alice.detach();
    await bob.detach();
  });

  test('F-20: forged replication frame cannot enter another conversation', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final secret = List<int>.generate(32, (i) => 12);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put(aliceId, secret)
      ..put(bobId, secret);
    final bindA = await signedDeviceBinding(peerId: aliceId, deviceId: 'dev-alice');
    final bindB = await signedDeviceBinding(peerId: bobId, deviceId: 'dev-bob');
    await pair.$1.start(
      TransportLocalConfiguration(peerId: aliceId, discoverySecret: secret),
    );
    await pair.$2.start(
      TransportLocalConfiguration(peerId: bobId, discoverySecret: secret),
    );
    await pair.$1.publish(bindA);
    await pair.$2.publish(bindB);

    final aliceIds = TrustedIdentityStore();
    final bobIds = TrustedIdentityStore();
    final aliceDev = DeviceRegistry();
    final bobDev = DeviceRegistry();
    trustContactPair(
      aliceIdentities: aliceIds,
      aliceDevices: aliceDev,
      bobIdentities: bobIds,
      bobDevices: bobDev,
      aliceBinding: bindA,
      bobBinding: bindB,
    );
    final alice = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('dev-alice'),
      selfPeerId: () => aliceId,
      selfDeviceId: 'dev-alice',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('dev-bob'),
      selfPeerId: () => bobId,
      selfDeviceId: 'dev-bob',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    ).attach();

    await pair.$1.connect(PeerDescriptor(peerId: bobId, discoverySecret: secret));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(alice.isAuthenticated(bobId), isTrue);
    final before = alice.hypercore.blocks.length;

    await pair.$2.send(
      aliceId,
      TransportChannel.replication,
      jsonPayload(<String, Object?>{
        'type': 'repl-event',
        'info': kReplicationEventInfo,
        'kind': ReplicationEventKind.messageEnvelopeCreated.name,
        'seq': 99,
        'writerDeviceId': 'forger',
        'fields': <String, Object?>{
          'conversationId': carolId,
          'encryptedEnvelope': base64Encode(utf8.encode('INJECTED-CAROL')),
          'senderIdentity': bobId,
        },
      }),
    );
    await pair.$2.send(
      aliceId,
      TransportChannel.replication,
      jsonPayload(<String, Object?>{
        'type': 'repl-event',
        'info': kReplicationEventInfo,
        'kind': ReplicationEventKind.deviceAuthorized.name,
        'seq': 100,
        'writerDeviceId': 'forger',
        'fields': <String, Object?>{
          'deviceId': 'forged-device',
          'ownerPeerId': aliceId,
          'audience': 'owner-devices',
        },
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(alice.hypercore.blocks.length, before);
    expect(
      alice.hypercore.blocks.any((r) {
        final env = r.fields['encryptedEnvelope'];
        if (env is List<int>) {
          return utf8.decode(env, allowMalformed: true).contains('INJECTED-CAROL');
        }
        return false;
      }),
      isFalse,
    );
    expect(
      alice.hypercore.blocks.any((r) => r.fields['deviceId'] == 'forged-device'),
      isFalse,
    );
    await alice.detach();
  });

  test('recordMayReplicateTo keeps device events off contacts', () {
    final device = _deviceEvent(ReplicationEventKind.deviceRevoked, 'phone-2');
    expect(
      recordMayReplicateTo(
        device,
        authenticatedPeerId: bobId,
        selfPeerId: aliceId,
        peerIsOwnDevice: false,
      ),
      isFalse,
    );
    expect(
      recordMayReplicateTo(
        device,
        authenticatedPeerId: aliceId,
        selfPeerId: aliceId,
        peerIsOwnDevice: true,
      ),
      isTrue,
    );
    final carol = _envelope(
      conversationId: carolId,
      ciphertext: Uint8List.fromList(const [1]),
    );
    expect(
      recordMayReplicateTo(
        carol,
        authenticatedPeerId: bobId,
        selfPeerId: aliceId,
        peerIsOwnDevice: false,
      ),
      isFalse,
    );
    expect(
      recordMayReplicateTo(
        carol,
        authenticatedPeerId: carolId,
        selfPeerId: aliceId,
        peerIsOwnDevice: false,
      ),
      isTrue,
    );
  });
}
