import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/calls/call_media_peer.dart';
import 'package:orbits_flutter/calls/hyperswarm_signaling.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/mailbox_protocol.dart';
import 'package:orbits_flutter/mailbox/storage_peer_client.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';
import 'package:orbits_flutter/peer/room_disclaimer.dart';
import 'package:orbits_flutter/peer/room_plaintext_gate.dart';
import 'package:orbits_flutter/rooms/autobase_log.dart';
import 'package:orbits_flutter/replication/drift_projector.dart';
import 'package:orbits_flutter/replication/file_journal.dart';
import 'package:orbits_flutter/replication/hypercore_store.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/dev_bare_transport.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';

import '../helpers/signed_device_binding.dart';

void main() {
  late DeviceBinding bindA;
  late DeviceBinding bindB;

  setUp(() async {
    resetFlagsForTests();
    bindA = await signedDeviceBinding(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'a',
    );
    bindB = await signedDeviceBinding(
      peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      deviceId: 'b',
    );
  });
  tearDown(resetFlagsForTests);

  final secret = List<int>.generate(32, (i) => 9);

  Future<(DualStackBridge, DualStackBridge, List<Object?>)> linked({
    Set<String> blocked = const {},
    BlindMailboxStore? mailbox,
  }) async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final packets = <Object?>[];
    final aliceDevices = DeviceRegistry();
    final bobDevices = DeviceRegistry();
    final aliceIdentities = TrustedIdentityStore();
    final bobIdentities = TrustedIdentityStore();
    trustContactPair(
      aliceIdentities: aliceIdentities,
      aliceDevices: aliceDevices,
      bobIdentities: bobIdentities,
      bobDevices: bobDevices,
      aliceBinding: bindA,
      bobBinding: bindB,
    );
    DualStackBridge make(
      LoopbackOrbitsTransport t,
      String self,
      String device,
    ) {
      final isAlice = self == 'ORBIT-AAAAAAAAAAAAAAAA';
      return DualStackBridge(
        transport: t,
        journal: MemoryJournal(device),
        selfPeerId: () => self,
        selfDeviceId: device,
        secrets: secrets,
        devices: isAlice ? aliceDevices : bobDevices,
        identities: isAlice ? aliceIdentities : bobIdentities,
        isBlocked: blocked.contains,
        mailbox: mailbox,
        mailboxToken: mailbox == null ? null : 'cap-1',
        mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
        onPacket: (peer, data) async {
          packets.add(data);
        },
      )..attach();
    }

    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(bindA);
    await pair.$2.publish(bindB);
    final a = make(pair.$1, 'ORBIT-AAAAAAAAAAAAAAAA', 'dev-a');
    final b = make(pair.$2, 'ORBIT-BBBBBBBBBBBBBBBB', 'dev-b');
    await pair.$1.connect(
      const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return (a, b, packets);
  }

  test('flag off never selects native even with a secret', () async {
    final (a, _, _) = await linked();
    resetFlagsForTests();
    expect(a.canUseNative('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);
  });

  test('blocked peer is dropped before packet delivery', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final seen = <Object?>[];
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
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
    DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (id) => id == 'ORBIT-AAAAAAAAAAAAAAAA',
      onPacket: (peer, data) async => seen.add(data),
    ).attach();
    await pair.$1.connect(
      const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
    );
    await pair.$1.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      utf8.encode('v2:hdr:iv:ct'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen, isEmpty);
  });

  test(
    'two natives exchange current wire + rooms + call signals without Hypercore',
    () async {
      final (a, b, packets) = await linked();
      expect(a.canUseNative('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
      kRoomPlaintextSessionAck.setAcknowledged(true);
      final rooms = <Map<String, Object?>>[];
      CallSignal? hangup;
      b.onPacket = (peer, data) async {
        if (data is Map) rooms.add(Map<String, Object?>.from(data));
        packets.add(data);
      };
      b.onCallSignal = (signal, from) {
        hangup = signal;
      };

      await a.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'wireHello',
        'v': 4,
      });
      await a.transport.send(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportChannel.message,
        utf8.encode('v2:aaa:bbb:ccc'),
      );
      expect(
        a.sendRoomPacket('ORBIT-BBBBBBBBBBBBBBBB', {
          'type': 'room_msg',
          'text': 'host-plaintext',
        }),
        isTrue,
      );
      final caller = NativeCallSession(
        send: (s) => a.sendCallSignal('ORBIT-BBBBBBBBBBBBBBBB', s),
        createPeer: () async => FakeCallMediaPeer(peerName: 'alice'),
      );
      await caller.startOutgoing(callId: 'c1', localStream: 'stream');
      await caller.addIce({'candidate': '1.2.3.4'});
      await caller.applyRemote(
        const CallSignal(
          type: CallSignalType.answer,
          callId: 'c1',
          sdp: 'answer-from-bob',
        ),
      );
      await a.sendCallSignal(
        'ORBIT-BBBBBBBBBBBBBBBB',
        const CallSignal(type: CallSignalType.hangup, callId: 'c1'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(
        packets.whereType<String>().any((p) => p.startsWith('v2:')),
        isTrue,
      );
      expect(rooms.any((r) => r['type'] == 'wireHello' && r['v'] == 4), isTrue);
      expect(
        rooms.any(
          (r) => r['type'] == 'room_msg' && r['text'] == 'host-plaintext',
        ),
        isTrue,
      );
      expect(hangup?.type, CallSignalType.hangup);
      expect(b.journal.length, greaterThan(0));
      expect(
        b.journal.records.every((r) => !r.fields.containsKey('plaintext')),
        isTrue,
      );
      expect(kRoomsApplicationE2eImplemented, isFalse);
      kRoomPlaintextSessionAck.reset();
    },
  );

  test('relay path change keeps the DualStack session and delivers', () async {
    final (a, b, packets) = await linked();
    expect(a.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    (a.transport as LoopbackOrbitsTransport).debugEmitPath(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportPath.relay,
    );
    await Future<void>.delayed(Duration.zero);
    expect(a.paths['ORBIT-BBBBBBBBBBBBBBBB'], TransportPath.relay);
    expect(a.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    expect(
      a.sendRoomPacket('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'room_msg',
        'text': 'via-relay',
      }),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      packets.whereType<Map>().any(
            (p) => p['type'] == 'room_msg' && p['text'] == 'via-relay',
          ),
      isTrue,
    );
  });

  test('room_autobase membership rides DualStack and Hypercore metadata',
      () async {
    final (a, b, packets) = await linked();
    final event = const RoomEvent(
      writerId: 'host',
      seq: 0,
      kind: 'membership',
      payload: {
        'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
        'action': 'join',
        'displayName': 'Bob',
      },
    );
    expect(
      a.sendRoomPacket(
        'ORBIT-BBBBBBBBBBBBBBBB',
        encodeRoomAutobasePacket('room-1', event),
      ),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    final inbound = packets.whereType<Map>().where(
          (p) => p['type'] == kRoomAutobaseType,
        );
    expect(inbound, isNotEmpty);
    final decoded = decodeRoomEventFromPacket(
      Map<String, Object?>.from(inbound.first),
    );
    expect(decoded, isNotNull);
    final guest = AutobaseProjection()..apply(decoded!);
    expect(guest.state.members['ORBIT-BBBBBBBBBBBBBBBB'], 'Bob');

    final recorded = a.journal.records.where(
      (r) => r.kind == ReplicationEventKind.roomMembershipChanged,
    );
    expect(recorded, isNotEmpty);
    expect(recorded.first.fields['action'], 'join');
    expect(recorded.first.fields['memberPeerId'], 'ORBIT-BBBBBBBBBBBBBBBB');
    expect(recorded.first.fields.containsKey('plaintext'), isFalse);
    expect(recorded.first.fields.containsKey('text'), isFalse);
    expect(recorded.first.fields.containsKey('displayName'), isFalse);
    expect(
      a.hypercore.blocks.any(
        (r) => r.kind == ReplicationEventKind.roomMembershipChanged,
      ),
      isTrue,
    );
    expect(kRoomsApplicationE2eImplemented, isFalse);

    expect(
      a.sendRoomPacket(
        'ORBIT-BBBBBBBBBBBBBBBB',
        encodeRoomAutobasePacket('room-1', event),
      ),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      a.journal.records
          .where((r) => r.kind == ReplicationEventKind.roomMembershipChanged)
          .length,
      1,
    );
  });

  test('recipient reads mailbox after the sender is gone', () async {
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 4096,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    final grantSecret = List<int>.generate(32, (i) => i + 5);
    final now = DateTime.now().millisecondsSinceEpoch;
    final cap = issueMailboxCapability(
      grantSecret: grantSecret,
      tokenId: 'tok-1',
      mailboxId: 'mb-alice-bob',
      scopes: MailboxScope.values.toSet(),
      issuedAt: now - 1000,
      notBefore: now - 1000,
      expiresAt: now + 60 * 1000,
      quotaBytes: 64 * 1024,
      retentionMs: 60 * 1000,
    );
    final client = StoragePeerClient.local(store, grantSecret: grantSecret);
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final seen = <Object?>[];
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
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
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      storagePeer: client,
      mailboxCapability: cap,
      onPacket: (peer, data) async {},
    )..attach();
    final b = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      storagePeer: client,
      mailboxCapability: cap,
      onPacket: (peer, data) async => seen.add(data),
    )..attach();
    // Ciphertext survives the sender going away.
    expect(
      await a.depositMailboxRemote(
        utf8.encode('v2:hdr:iv:ct'),
        envelopeId: 'e1',
      ),
      isTrue,
    );
    await pair.$1.stop();
    expect(await b.drainMailbox(), 0);
    final n = await b.drainMailbox(fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA');
    expect(n, 1);
    expect(seen, ['v2:hdr:iv:ct']);

    // Non-ciphertext is never attributed or journaled, even on an
    // explicit per-sender bucket.
    seen.clear();
    expect(
      await a.depositMailboxRemote(
        utf8.encode(jsonEncode({'type': 'wireHello', 'v': 4})),
        envelopeId: 'e-hello',
      ),
      isTrue,
    );
    expect(
      await b.drainMailbox(fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA'),
      0,
    );
    expect(seen, isEmpty);
    expect(b.lastReplicationError, 'unbucketed-legacy-skipped');
    await a.detach();
    await b.detach();
  });

  test('offline send without a storage peer stays pending, ratchet untouched',
      () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
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
    // Two SEPARATE local stores: a local deposit is not delivery.
    MailboxCapability mkCap(String token) => MailboxCapability(
          token: token,
          quotaBytes: 4096,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        );
    final aliceStore = BlindMailboxStore()..grant(mkCap('cap-a'));
    final bobStore = BlindMailboxStore()..grant(mkCap('cap-b'));
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      isBlocked: (_) => false,
      mailbox: aliceStore,
      mailboxToken: 'cap-a',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      onPacket: (peer, data) async {},
    )..attach();
    final b = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      mailbox: bobStore,
      mailboxToken: 'cap-b',
      mailboxWriterKey: 'ORBIT-BBBBBBBBBBBBBBBB',
      onPacket: (peer, data) async {},
    )..attach();
    await a.dial('ORBIT-BBBBBBBBBBBBBBBB');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(a.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    await pair.$1.disconnect('ORBIT-BBBBBBBBBBBBBBBB');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(a.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);

    expect(
      await a.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'wireHello',
        'v': 4,
      }),
      isFalse,
    );
    expect(
      await a.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'msg',
        'text': 'no-peer',
      }),
      isFalse,
    );
    expect(
      await b.drainMailbox(fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA'),
      0,
    );
    expect(b.journal.length, 0);
    await a.detach();
    await b.detach();
  });

  test('mailbox drain skips blocked senders and does not invent a sender', () async {
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 4096,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    final blocked = DualStackBridge(
      transport: LoopbackOrbitsTransport(),
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      isBlocked: (id) => id == 'ORBIT-AAAAAAAAAAAAAAAA',
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      onPacket: (_, __) async {},
    )..attach();
    expect(
      blocked.depositMailbox(
        utf8.encode('v2:hdr:iv:ct'),
        writerKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      ),
      isTrue,
    );
    expect(await blocked.drainMailbox(), 0);
    expect(
      await blocked.drainMailbox(fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA'),
      0,
    );
    expect(blocked.journal.length, 0);
    await blocked.detach();
  });

  test('drainKnownMailboxes projects only unblocked known senders', () async {
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 4096,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    final seen = <String>[];
    final bridge = DualStackBridge(
      transport: LoopbackOrbitsTransport(),
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      isBlocked: (id) => id == 'ORBIT-CCCCCCCCCCCCCCCC',
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-BBBBBBBBBBBBBBBB',
      onPacket: (peer, _) async => seen.add(peer),
    )..attach();
    expect(
      bridge.depositMailbox(
        utf8.encode('v2:hdr:iv:ct'),
        writerKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      ),
      isTrue,
    );
    expect(
      bridge.depositMailbox(
        utf8.encode('v2:hdr:iv:other'),
        writerKey: 'ORBIT-CCCCCCCCCCCCCCCC',
      ),
      isTrue,
    );
    expect(await bridge.drainKnownMailboxes(const <String>[]), 0);
    expect(
      await bridge.drainKnownMailboxes(const [
        'ORBIT-CCCCCCCCCCCCCCCC',
        'ORBIT-AAAAAAAAAAAAAAAA',
      ]),
      1,
    );
    expect(seen, ['ORBIT-AAAAAAAAAAAAAAAA']);
    await bridge.detach();
  });

  test('drainKnownMailboxes keeps per-sender buckets', () async {
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 4096,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    final seen = <String>[];
    final bridge = DualStackBridge(
      transport: LoopbackOrbitsTransport(),
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      onPacket: (peer, _) async => seen.add(peer),
    )..attach();
    expect(
      bridge.depositMailbox(
        utf8.encode('v2:hdr:iv:alice'),
        writerKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      ),
      isTrue,
    );
    expect(
      bridge.depositMailbox(
        utf8.encode('v2:hdr:iv:dana'),
        writerKey: 'ORBIT-DDDDDDDDDDDDDDDD',
      ),
      isTrue,
    );
    expect(
      await bridge.drainKnownMailboxes(const [
        'ORBIT-AAAAAAAAAAAAAAAA',
        'ORBIT-DDDDDDDDDDDDDDDD',
      ]),
      2,
    );
    expect(
      seen,
      ['ORBIT-AAAAAAAAAAAAAAAA', 'ORBIT-DDDDDDDDDDDDDDDD'],
    );
    await bridge.detach();
  });

  test('mailbox drain without conversation members fails closed', () async {
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 4096,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    final bridge = DualStackBridge(
      transport: LoopbackOrbitsTransport(),
      journal: MemoryJournal('b'),
      selfPeerId: () => '',
      selfDeviceId: 'b',
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      onPacket: (_, __) async {},
    )..attach();
    expect(
      bridge.depositMailbox(
        utf8.encode('v2:hdr:iv:ct'),
        writerKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      ),
      isTrue,
    );
    expect(
      await bridge.drainKnownMailboxes(const ['ORBIT-AAAAAAAAAAAAAAAA']),
      0,
    );
    expect(bridge.lastReplicationError, contains('conversation members required'));
    expect(bridge.journal.length, 0);
    await bridge.detach();
  });

  test('mailbox drain uses mailboxWriterKey when selfPeerId is empty', () async {
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 4096,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    final bridge = DualStackBridge(
      transport: LoopbackOrbitsTransport(),
      journal: MemoryJournal('b'),
      selfPeerId: () => '',
      selfDeviceId: 'b',
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-BBBBBBBBBBBBBBBB',
      onPacket: (_, __) async {},
    )..attach();
    expect(
      bridge.depositMailbox(
        utf8.encode('v2:hdr:iv:writer-key'),
        writerKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      ),
      isTrue,
    );
    expect(
      await bridge.drainKnownMailboxes(const ['ORBIT-AAAAAAAAAAAAAAAA']),
      1,
    );
    expect(bridge.journal.length, 1);
    await bridge.detach();
  });

  test('malformed call frame is visible on lastCallSignalError', () async {
    final (a, b, _) = await linked();
    var seen = 0;
    b.onCallSignal = (_, __) {
      seen += 1;
    };
    await a.transport.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.call,
      utf8.encode('not-json'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(seen, 0);
    expect(b.lastCallSignalError, isNotEmpty);
    await a.sendCallSignal(
      'ORBIT-BBBBBBBBBBBBBBBB',
      const CallSignal(type: CallSignalType.hangup, callId: 'c-ok'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(seen, 1);
    expect(b.lastCallSignalError, isEmpty);
  });

  test('membership Hypercore append failure is visible and does not send',
      () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
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
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(bindA);
    await pair.$2.publish(bindB);
    final seen = <Object?>[];
    final alice = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      hypercore: _ThrowingHypercore('a'),
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, data) async => seen.add(data),
    ).attach();
    await alice.dial('ORBIT-BBBBBBBBBBBBBBBB');
    expect(
      alice.sendRoomPacket(
        'ORBIT-BBBBBBBBBBBBBBBB',
        encodeRoomAutobasePacket(
          'room-1',
          const RoomEvent(
            writerId: 'host',
            seq: 0,
            kind: 'membership',
            payload: {
              'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
              'action': 'join',
            },
          ),
        ),
      ),
      isFalse,
    );
    expect(alice.lastReplicationError, contains('hypercore-append-failed'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen, isEmpty);
    // A retry must not slip through the journal dedup without Hypercore.
    expect(
      alice.sendRoomPacket(
        'ORBIT-BBBBBBBBBBBBBBBB',
        encodeRoomAutobasePacket(
          'room-1',
          const RoomEvent(
            writerId: 'host',
            seq: 0,
            kind: 'membership',
            payload: {
              'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
              'action': 'join',
            },
          ),
        ),
      ),
      isFalse,
    );
    expect(alice.lastReplicationError, contains('hypercore-append-failed'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen, isEmpty);
    await alice.detach();
  });

  test('live membership projector matches FileJournal replay', () async {
    final durable = FileJournal.memory('a');
    Future<Map<String, Object?>?> decrypt(List<int> _, JournalRecord __) async =>
        null;
    final live = JournalProjector(decrypt: decrypt, persistEnvelopePlaintext: true);
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
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
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(bindA);
    await pair.$2.publish(bindB);
    final alice = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      durableJournal: durable,
      onRemoteRecord: live.apply,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    ).attach();
    await alice.dial('ORBIT-BBBBBBBBBBBBBBBB');
    expect(
      alice.sendRoomPacket(
        'ORBIT-BBBBBBBBBBBBBBBB',
        encodeRoomAutobasePacket(
          'room-1',
          const RoomEvent(
            writerId: 'host',
            seq: 0,
            kind: 'membership',
            payload: {
              'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
              'action': 'join',
            },
          ),
        ),
      ),
      isTrue,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (live.membershipChanges.isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(live.membershipChanges, isNotEmpty);
    expect(live.membershipChanges.single['action'], 'join');
    expect(
      live.membershipChanges.single['memberPeerId'],
      'ORBIT-BBBBBBBBBBBBBBBB',
    );
    expect(live.membershipChanges.single['roomId'], 'room-1');

    final replay = JournalProjector(decrypt: decrypt, persistEnvelopePlaintext: true);
    await replay.applyAll(await durable.replay());
    expect(replay.membershipChanges, live.membershipChanges);
    expect(live.messages, isEmpty);
    expect(kRoomsApplicationE2eImplemented, isFalse);
    await alice.detach();
  });

  test('drop chunks and hypercore replication ride native channels', () async {
    final (a, b, _) = await linked();
    final dropped = <Object>[];
    b.onDrop = (peer, packet) => dropped.add(packet);
    await a.sendDrop('ORBIT-BBBBBBBBBBBBBBBB', {
      'type': 'file-start',
      'fileId': 'f1',
      'name': 'a.bin',
      'size': 3,
    });
    await a.transport.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      utf8.encode('v2:aaa:bbb:ccc'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      dropped.whereType<Map>().any((m) => m['type'] == 'file-start'),
      isTrue,
    );
    expect(b.hypercore.blocks, isNotEmpty);
    expect(
      b.hypercore.blocks.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(
      b.hypercore.blocks.any(
        (r) => r.fields['senderIdentity'] == 'ORBIT-AAAAAAAAAAAAAAAA',
      ),
      isTrue,
    );
  });

  test(
    'device revoke is journaled and drops that writer from fan-out',
    () async {
      setHyperswarmRollout(HyperswarmRollout.internal);
      final pair = loopbackPair();
      final secrets = DiscoverySecretStore()
        ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
        ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
      final devices = DeviceRegistry();
      final a = DualStackBridge(
        transport: pair.$1,
        journal: MemoryJournal('dev-a'),
        selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
        selfDeviceId: 'dev-a',
        secrets: secrets,
        devices: devices,
        isBlocked: (_) => false,
        onPacket: (_, __) async {},
      )..attach();
      a.authorizeDevice(
        AuthorizedDevice(
          deviceId: 'phone-2',
          transportPublicKey: List<int>.filled(32, 1),
          hypercorePublicKey: List<int>.filled(32, 2),
          name: 'phone-2',
          kind: 'phone',
          createdAt: 1,
          status: DeviceStatus.active,
          ownerPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
          transportPeerId: 'ORBIT-B2B2B2B2B2B2B2B2',
        ),
      );
      expect(
        devices.transportTargets('ORBIT-BBBBBBBBBBBBBBBB'),
        contains('ORBIT-B2B2B2B2B2B2B2B2'),
      );
      a.revokeDevice('phone-2');
      expect(devices.acceptsWriter('phone-2'), isFalse);
      expect(
        devices.transportTargets('ORBIT-BBBBBBBBBBBBBBBB'),
        isNot(contains('ORBIT-B2B2B2B2B2B2B2B2')),
      );
      expect(
        a.journal.records.any(
          (r) => r.kind == ReplicationEventKind.deviceRevoked,
        ),
        isTrue,
      );
      expect(
        a.journal.records.every((r) => !r.fields.containsKey('plaintext')),
        isTrue,
      );
      await a.detach();
    },
  );

  test('dev Bare path dials with the shared contact secret', () async {
    hydrateDevBareTransportPref(true);
    expect(isHyperswarmTransportEnabled(), isTrue);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
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
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      isBlocked: (_) => false,
      onPacket: (peer, data) async {},
    )..attach();
    DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (peer, data) async {},
    ).attach();
    await a.dial('ORBIT-BBBBBBBBBBBBBBBB');
    expect(a.isNativeConnected('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    expect(
      await a.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'wireHello',
        'v': 4,
      }),
      isTrue,
    );
    await a.detach();
  });

  test('room_msg is blocked without the plaintext ack', () {
    kRoomPlaintextSessionAck.reset();
    expect(
      sendGuardedRoomPacket(
        {'type': 'room_msg', 'text': 'x'},
        connected: true,
        send: (_) => true,
      ),
      isFalse,
    );
  });

  test('sendGuardedRoomPacket propagates send() false', () {
    kRoomPlaintextSessionAck.setAcknowledged(true);
    addTearDown(kRoomPlaintextSessionAck.reset);
    expect(
      sendGuardedRoomPacket(
        {'type': 'room_autobase', 'kind': 'membership'},
        connected: true,
        send: (_) => false,
      ),
      isFalse,
    );
  });
}

class _ThrowingHypercore extends HypercoreLocalStore {
  _ThrowingHypercore(super.writerDeviceId);

  @override
  JournalRecord append(JournalRecord record) {
    throw StateError('hypercore-append-failed');
  }
}
