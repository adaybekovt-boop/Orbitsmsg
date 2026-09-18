import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/double_ratchet.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/devices/device_link.dart';
import 'package:orbits_flutter/devices/device_ratchet_sessions.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/mailbox_protocol.dart';
import 'package:orbits_flutter/mailbox/storage_peer_client.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';

import '../helpers/pointycastle_ecdh.dart';
import '../helpers/signed_device_binding.dart';

Future<(RatchetState, RatchetState)> _pair() async {
  final shared = List<int>.generate(32, (i) => i + 3);
  final bobDh = await generateDhKeyPair();
  final bobSpki = await exportSpkiBytes(bobDh);
  final alice = await ratchetInitAlice(
    sharedSecret: shared,
    remoteDhPubSpki: bobSpki,
  );
  final bob = await ratchetInitBob(
    sharedSecret: shared,
    dhKeyPair: bobDh,
    dhPubSpki: bobSpki,
  );
  final hello = await ratchetEncrypt(alice, 'handshake');
  expect(utf8.decode(await ratchetDecrypt(bob, hello)), 'handshake');
  return (alice, bob);
}

void main() {
  installPointyCastleEcdh();

  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  test('DualStack fan-out uses per-device ratchets and revoke drops the device',
      () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final secret = List<int>.generate(32, (i) => 11);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final bindA = await signedDeviceBinding(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-a',
    );
    final bindB = await signedDeviceBinding(
      peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      deviceId: 'dev-b',
    );
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

    final (aliceState, bobState) = await _pair();
    final aliceRatchets = DeviceRatchetSessions(localDeviceId: 'dev-a')
      ..bind(
        localDeviceId: 'dev-a',
        remoteDeviceId: 'dev-b',
        state: aliceState,
      );
    final bobRatchets = DeviceRatchetSessions(localDeviceId: 'dev-b')
      ..bind(
        localDeviceId: 'dev-b',
        remoteDeviceId: 'dev-a',
        state: bobState,
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

    final packets = <Object?>[];
    final alice = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('dev-a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'dev-a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      ratchets: aliceRatchets,
      isBlocked: (_) => false,
      onPacket: (_, data) async {},
    )..attach();
    DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('dev-b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'dev-b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      ratchets: bobRatchets,
      isBlocked: (_) => false,
      onPacket: (_, data) async => packets.add(data),
    ).attach();

    await alice.dial('ORBIT-BBBBBBBBBBBBBBBB');
    expect(alice.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    expect(
      await alice.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'msg',
        'text': 'per-device',
      }),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(packets, isNotEmpty);
    final first = packets.whereType<AuthenticatedPlaintext>().first;
    expect(first.data['text'], 'per-device');

    alice.revokeDevice('dev-b');
    expect(alice.ratchets.isRevoked('dev-b'), isTrue);
    expect(alice.ratchets.session('dev-a', 'dev-b'), isNull);

    await alice.detach();
  });

  test('authenticated DualStack mints a per-device ratchet without a pre-bound session',
      () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final secret = List<int>.generate(32, (i) => 13);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final bindA = await signedDeviceBinding(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-a',
    );
    final bindB = await signedDeviceBinding(
      peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      deviceId: 'dev-b',
    );
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

    final packets = <Object?>[];
    final alice = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('dev-a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'dev-a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('dev-b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'dev-b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, data) async => packets.add(data),
    ).attach();

    await alice.dial('ORBIT-BBBBBBBBBBBBBBBB');
    expect(alice.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(alice.ratchets.session('dev-a', 'dev-b'), isNotNull);
    expect(
      await alice.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'msg',
        'text': 'minted',
      }),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      packets.whereType<AuthenticatedPlaintext>().any(
            (p) => p.data['text'] == 'minted',
          ),
      isTrue,
    );
    await alice.detach();
  });

  test('offline device-ratchet fan-out drains as a typed frame, not peer wire',
      () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final secret = List<int>.generate(32, (i) => 19);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final bindA = await signedDeviceBinding(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-a',
    );
    final bindB = await signedDeviceBinding(
      peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      deviceId: 'dev-b',
    );
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
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 64 * 1024,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    // A shared local store is not delivery: the offline fan-out needs a
    // real (here: local-loopback) storage peer + capability.
    final grantSecret = List<int>.generate(32, (i) => i + 9);
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

    final packets = <Object?>[];
    final alice = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('dev-a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'dev-a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      storagePeer: client,
      mailboxCapability: cap,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    final bob = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('dev-b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'dev-b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      storagePeer: client,
      mailboxCapability: cap,
      isBlocked: (_) => false,
      onPacket: (_, data) async => packets.add(data),
    )..attach();

    await alice.dial('ORBIT-BBBBBBBBBBBBBBBB');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(alice.ratchets.session('dev-a', 'dev-b'), isNotNull);
    expect(bob.ratchets.session('dev-b', 'dev-a'), isNotNull);

    await pair.$1.disconnect('ORBIT-BBBBBBBBBBBBBBBB');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(alice.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);

    expect(
      await alice.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'msg',
        'text': 'mailbox-device',
      }),
      isTrue,
    );
    final n = await bob.drainMailbox(fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA');
    expect(n, greaterThan(0));
    expect(
      packets.whereType<AuthenticatedPlaintext>().any(
            (p) => p.data['text'] == 'mailbox-device',
          ),
      isTrue,
    );
    await alice.detach();
    await bob.detach();
  });

  test('three-device DualStack mesh fans out, syncs, and revoke drops one',
      () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final secret = List<int>.generate(32, (i) => 23);
    final triple = loopbackTriple();
    const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
    const tabletTransport = 'ORBIT-CCCCCCCCCCCCCCCC';
    final secrets = DiscoverySecretStore()
      ..put(alice, secret)
      ..put(bob, secret)
      ..put(tabletTransport, secret);
    final aliceId = await signedIdentity(alice);
    final bobId = await signedIdentity(bob);
    final bindPhone = await signedDeviceBinding(
      peerId: alice,
      deviceId: 'alice-phone',
      identity: aliceId,
    );
    final bindTablet = await signedDeviceBinding(
      peerId: alice,
      deviceId: 'alice-tablet',
      identity: aliceId,
    );
    final bindBob = await signedDeviceBinding(
      peerId: bob,
      deviceId: 'bob-phone',
      identity: bobId,
    );

    final phoneIds = TrustedIdentityStore();
    final tabletIds = TrustedIdentityStore();
    final bobIds = TrustedIdentityStore();
    final phoneDev = DeviceRegistry();
    final tabletDev = DeviceRegistry();
    final bobDev = DeviceRegistry();

    void trustAll(TrustedIdentityStore ids, DeviceRegistry devices) {
      trustBinding(
        identities: ids,
        devices: devices,
        binding: bindPhone,
        isSelf: true,
        transportPeerId: alice,
      );
      trustBinding(
        identities: ids,
        devices: devices,
        binding: bindTablet,
        isSelf: true,
        transportPeerId: tabletTransport,
      );
      trustBinding(
        identities: ids,
        devices: devices,
        binding: bindBob,
        transportPeerId: bob,
      );
    }

    trustAll(phoneIds, phoneDev);
    trustAll(tabletIds, tabletDev);
    trustBinding(
      identities: bobIds,
      devices: bobDev,
      binding: bindBob,
      isSelf: true,
      transportPeerId: bob,
    );
    trustBinding(
      identities: bobIds,
      devices: bobDev,
      binding: bindPhone,
      transportPeerId: alice,
    );
    trustBinding(
      identities: bobIds,
      devices: bobDev,
      binding: bindTablet,
      transportPeerId: tabletTransport,
    );

    await triple.$1.start(
      TransportLocalConfiguration(peerId: alice, discoverySecret: secret),
    );
    await triple.$2.start(
      TransportLocalConfiguration(
        peerId: tabletTransport,
        discoverySecret: secret,
      ),
    );
    await triple.$3.start(
      TransportLocalConfiguration(peerId: bob, discoverySecret: secret),
    );
    await triple.$1.publish(bindPhone);
    await triple.$2.publish(bindTablet);
    await triple.$3.publish(bindBob);

    final tabletPackets = <Object?>[];
    final bobPackets = <Object?>[];
    final phone = DualStackBridge(
      transport: triple.$1,
      journal: MemoryJournal('alice-phone'),
      selfPeerId: () => alice,
      selfDeviceId: 'alice-phone',
      secrets: secrets,
      devices: phoneDev,
      identities: phoneIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    final tablet = DualStackBridge(
      transport: triple.$2,
      journal: MemoryJournal('alice-tablet'),
      selfPeerId: () => alice,
      selfDeviceId: 'alice-tablet',
      secrets: secrets,
      devices: tabletDev,
      identities: tabletIds,
      isBlocked: (_) => false,
      onPacket: (_, data) async => tabletPackets.add(data),
    )..attach();
    final bobBridge = DualStackBridge(
      transport: triple.$3,
      journal: MemoryJournal('bob-phone'),
      selfPeerId: () => bob,
      selfDeviceId: 'bob-phone',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, data) async => bobPackets.add(data),
    )..attach();

    await phone.dial(bob);
    await phone.dial(tabletTransport);
    await bobBridge.dial(tabletTransport);
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (phone.ratchets.session('alice-phone', 'bob-phone') != null &&
          phone.ratchets.session('alice-phone', 'alice-tablet') != null &&
          tablet.ratchets.session('alice-tablet', 'bob-phone') != null) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(phone.ratchets.session('alice-phone', 'bob-phone'), isNotNull);
    expect(phone.ratchets.session('alice-phone', 'alice-tablet'), isNotNull);
    expect(tablet.ratchets.session('alice-tablet', 'bob-phone'), isNotNull);
    expect(
      identical(
        phone.ratchets.session('alice-phone', 'bob-phone'),
        tablet.ratchets.session('alice-tablet', 'bob-phone'),
      ),
      isFalse,
    );

    expect(
      await phone.sendEncrypted(bob, {'type': 'msg', 'text': 'mesh-hi'}),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      bobPackets.whereType<AuthenticatedPlaintext>().any(
            (p) => p.data['text'] == 'mesh-hi',
          ),
      isTrue,
    );
    expect(
      tabletPackets.whereType<AuthenticatedPlaintext>().any(
            (p) => p.data['text'] == 'mesh-hi',
          ),
      isTrue,
    );

    bobBridge.revokeDevice('alice-tablet');
    bobPackets.clear();
    tabletPackets.clear();
    expect(
      await bobBridge.sendEncrypted(alice, {
        'type': 'msg',
        'text': 'after-revoke',
      }),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      tabletPackets.whereType<AuthenticatedPlaintext>(),
      isEmpty,
    );

    await phone.detach();
    await tablet.detach();
    await bobBridge.detach();
  });

  test('QR acceptDeviceLink authorizes and DualStack admit mints ratchets',
      () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    resetDeviceLinkChallengesForTests();
    final secret = List<int>.generate(32, (i) => 29);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final aliceIdentity = await signedIdentity('ORBIT-AAAAAAAAAAAAAAAA');
    final bindA = await signedDeviceBinding(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-a',
      identity: aliceIdentity,
    );
    final bindB = await signedDeviceBinding(
      peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      deviceId: 'dev-b',
    );
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
      journal: MemoryJournal('dev-a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'dev-a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('dev-b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'dev-b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    ).attach();

    final link = await issueDeviceLink(
      deviceId: 'dev-linked',
      transportPublicKey: Uint8List.fromList(
        List<int>.generate(32, (i) => i + 3),
      ),
      hypercorePublicKey: Uint8List.fromList(
        List<int>.generate(32, (i) => i + 4),
      ),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      identityPublicKey: aliceIdentity.spki,
      sign: (payload) async => signP256Ecdsa(aliceIdentity.pair, payload),
      ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      transportPeerId: 'ORBIT-CCCCCCCCCCCCCCCC',
    );
    expect(jsonEncode(link.toQrJson()).toLowerCase().contains('priv'), isFalse);
    expect(
      await acceptDeviceLink(
        link,
        ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        registry: aliceDev,
        identities: aliceIds,
        onAuthorized: alice.authorizeDevice,
      ),
      isTrue,
    );
    expect(aliceDev.byId('dev-linked'), isNotNull);
    expect(alice.ratchets.session('dev-a', 'dev-linked'), isNull);
    // authorizeDevice journals async (sign-then-append): pump first.
    final journalDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(journalDeadline)) {
      if (alice.journal.records.any(
        (r) =>
            r.kind == ReplicationEventKind.deviceAuthorized &&
            r.fields['deviceId'] == 'dev-linked',
      )) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      alice.journal.records.any(
        (r) =>
            r.kind == ReplicationEventKind.deviceAuthorized &&
            r.fields['deviceId'] == 'dev-linked',
      ),
      isTrue,
    );

    await alice.dial('ORBIT-BBBBBBBBBBBBBBBB');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(alice.ratchets.session('dev-a', 'dev-b'), isNotNull);
    await alice.detach();
  });

  test('DualStack + vault snapshot hydrates and revoke survives restart',
      () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final secret = List<int>.generate(32, (i) => 31);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final bindA = await signedDeviceBinding(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-a',
    );
    final bindB = await signedDeviceBinding(
      peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      deviceId: 'dev-b',
    );
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

    final savedA = <int>[];
    final savedB = <int>[];
    DeviceRatchetSessions makeA() => DeviceRatchetSessions(
          localDeviceId: 'dev-a',
          writeSnapshot: (bytes) async {
            savedA
              ..clear()
              ..addAll(bytes);
          },
          readSnapshot: () async => Uint8List.fromList(savedA),
        );
    DeviceRatchetSessions makeB() => DeviceRatchetSessions(
          localDeviceId: 'dev-b',
          writeSnapshot: (bytes) async {
            savedB
              ..clear()
              ..addAll(bytes);
          },
          readSnapshot: () async => Uint8List.fromList(savedB),
        );

    final liveA = makeA();
    final liveB = makeB();
    final firstPackets = <Object?>[];
    final alice = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('dev-a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'dev-a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      ratchets: liveA,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    final bob = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('dev-b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'dev-b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      ratchets: liveB,
      isBlocked: (_) => false,
      onPacket: (_, data) async => firstPackets.add(data),
    )..attach();

    await alice.dial('ORBIT-BBBBBBBBBBBBBBBB');
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (liveA.session('dev-a', 'dev-b') != null &&
          liveB.session('dev-b', 'dev-a') != null) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(liveA.session('dev-a', 'dev-b'), isNotNull);
    expect(
      await alice.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'msg',
        'text': 'before-restart',
      }),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      firstPackets.whereType<AuthenticatedPlaintext>().any(
            (p) => p.data['text'] == 'before-restart',
          ),
      isTrue,
    );
    await liveA.persist();
    await liveB.persist();
    expect(savedA, isNotEmpty);
    expect(savedB, isNotEmpty);
    await alice.detach();
    await bob.detach();
    try {
      await pair.$1.disconnect('ORBIT-BBBBBBBBBBBBBBBB');
    } catch (_) {}
    try {
      await pair.$2.disconnect('ORBIT-AAAAAAAAAAAAAAAA');
    } catch (_) {}

    final restoredA = makeA();
    final restoredB = makeB();
    await restoredA.hydrate();
    await restoredB.hydrate();
    expect(restoredA.session('dev-a', 'dev-b'), isNotNull);
    expect(restoredB.session('dev-b', 'dev-a'), isNotNull);

    final restartPackets = <Object?>[];
    final alice2 = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('dev-a-2'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'dev-a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      ratchets: restoredA,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    final bob2 = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('dev-b-2'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'dev-b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      ratchets: restoredB,
      isBlocked: (_) => false,
      onPacket: (_, data) async => restartPackets.add(data),
    )..attach();

    await alice2.dial('ORBIT-BBBBBBBBBBBBBBBB');
    final authDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(authDeadline)) {
      if (alice2.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB') &&
          bob2.isAuthenticated('ORBIT-AAAAAAAAAAAAAAAA')) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(alice2.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    expect(bob2.isAuthenticated('ORBIT-AAAAAAAAAAAAAAAA'), isTrue);
    expect(
      await alice2.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'msg',
        'text': 'after-restart',
      }),
      isTrue,
    );
    final recvDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(recvDeadline)) {
      if (restartPackets.whereType<AuthenticatedPlaintext>().any(
            (p) => p.data['text'] == 'after-restart',
          )) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      restartPackets.whereType<AuthenticatedPlaintext>().any(
            (p) => p.data['text'] == 'after-restart',
          ),
      isTrue,
    );

    alice2.revokeDevice('dev-b');
    expect(restoredA.isRevoked('dev-b'), isTrue);
    await restoredA.persist();
    final afterRevoke = makeA();
    await afterRevoke.hydrate();
    expect(afterRevoke.isRevoked('dev-b'), isTrue);
    expect(afterRevoke.session('dev-a', 'dev-b'), isNull);
    await alice2.detach();
    await bob2.detach();
  });

  test('device-ratchet decrypt failure is visible', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final secret = List<int>.generate(32, (i) => 19);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final bindA = await signedDeviceBinding(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-a',
    );
    final bindB = await signedDeviceBinding(
      peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      deviceId: 'dev-b',
    );
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
      journal: MemoryJournal('dev-a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'dev-a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    final bob = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('dev-b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'dev-b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    await alice.dial('ORBIT-BBBBBBBBBBBBBBBB');
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (bob.isAuthenticated('ORBIT-AAAAAAAAAAAAAAAA')) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(bob.lastDeviceRatchetError, isEmpty);
    await pair.$1.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      utf8.encode(
        jsonEncode(
          encodeDeviceRatchetFrame(
            fromDeviceId: 'dev-a',
            toDeviceId: 'dev-b',
            wire: 'v2:not:a:real:ratchet',
          ),
        ),
      ),
    );
    final errDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(errDeadline)) {
      if (bob.lastDeviceRatchetError.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(bob.lastDeviceRatchetError, isNotEmpty);
    await alice.detach();
    await bob.detach();
  });
}
