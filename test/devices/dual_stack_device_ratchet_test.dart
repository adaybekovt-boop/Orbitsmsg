import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/double_ratchet.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/devices/device_ratchet_sessions.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
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
    final first = packets.whereType<AuthenticatedPlaintext>().first;
    expect(first.data['text'], 'minted');
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
    final plain = packets.whereType<AuthenticatedPlaintext>().first;
    expect(plain.data['text'], 'mailbox-device');
    await alice.detach();
    await bob.detach();
  });
}
