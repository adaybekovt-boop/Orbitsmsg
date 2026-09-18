import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/calls/hyperswarm_signaling.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/state/connections_notifier.dart';
import 'package:orbits_flutter/transport/dev_bare_transport.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';

import '../helpers/signed_device_binding.dart';

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  test('Bare connected without PeerJS is reliable for outbox flush', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    hydrateDevBareTransportPref(true);
    const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
    final secret = List<int>.generate(32, (i) => 4);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put(alice, secret)
      ..put(bob, secret);
    final bindA = await signedDeviceBinding(peerId: alice, deviceId: 'a');
    final bindB = await signedDeviceBinding(peerId: bob, deviceId: 'b');
    await pair.$1.start(
      TransportLocalConfiguration(peerId: alice, discoverySecret: secret),
    );
    await pair.$2.start(
      TransportLocalConfiguration(peerId: bob, discoverySecret: secret),
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
      selfPeerId: () => bob,
      selfDeviceId: 'b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    ).attach();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final conns = container.read(connectionsNotifierProvider.notifier);
    conns.bindNativeTransport(
      pair.$1,
      journal: MemoryJournal('a'),
      deviceId: 'a',
      devices: aliceDev,
      identities: aliceIds,
    );
    discoverySecretStore.put(alice, secret);
    discoverySecretStore.put(bob, secret);
    await pair.$1.connect(const PeerDescriptor(peerId: bob));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(conns.nativeBridge!.isAuthenticated(bob), isTrue);
    expect(conns.hasReliable(bob), isTrue);
    expect(conns.getConn(bob, 'reliable'), isNull);
    expect(conns.peerjsFallbackCloseCalls, greaterThan(0));

    await pair.$1.disconnect(bob);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(conns.hasReliable(bob), isFalse);
  });

  test('openReliable tears down a pre-opened PeerJS slot after native auth',
      () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    hydrateDevBareTransportPref(true);
    const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
    final secret = List<int>.generate(32, (i) => 6);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put(alice, secret)
      ..put(bob, secret);
    final bindA = await signedDeviceBinding(peerId: alice, deviceId: 'a');
    final bindB = await signedDeviceBinding(peerId: bob, deviceId: 'b');
    await pair.$1.start(
      TransportLocalConfiguration(peerId: alice, discoverySecret: secret),
    );
    await pair.$2.start(
      TransportLocalConfiguration(peerId: bob, discoverySecret: secret),
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
      selfPeerId: () => bob,
      selfDeviceId: 'b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    ).attach();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final conns = container.read(connectionsNotifierProvider.notifier);
    var disposed = 0;
    conns.debugAttachPeerjsSlot(bob, onDispose: () async {
      disposed += 1;
    });
    expect(conns.debugHasPeerjsSlot(bob), isTrue);
    conns.bindNativeTransport(
      pair.$1,
      journal: MemoryJournal('a'),
      deviceId: 'a',
      devices: aliceDev,
      identities: aliceIds,
    );
    discoverySecretStore.put(alice, secret);
    discoverySecretStore.put(bob, secret);
    expect(conns.debugHasPeerjsSlot(bob), isTrue);
    conns.openReliable(bob);
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (conns.canUseNative(bob) &&
          disposed > 0 &&
          !conns.debugHasPeerjsSlot(bob)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(conns.canUseNative(bob), isTrue);
    expect(disposed, greaterThan(0));
    expect(conns.debugHasPeerjsSlot(bob), isFalse);
    expect(conns.peerjsFallbackCloseCalls, greaterThan(0));
    expect(conns.getConn(bob, 'reliable'), isNull);
  });

  test('sendCallSignal uses DualStack and does not open PeerJS', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    hydrateDevBareTransportPref(true);
    const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
    final secret = List<int>.generate(32, (i) => 8);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put(alice, secret)
      ..put(bob, secret);
    final bindA = await signedDeviceBinding(peerId: alice, deviceId: 'a');
    final bindB = await signedDeviceBinding(peerId: bob, deviceId: 'b');
    await pair.$1.start(
      TransportLocalConfiguration(peerId: alice, discoverySecret: secret),
    );
    await pair.$2.start(
      TransportLocalConfiguration(peerId: bob, discoverySecret: secret),
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
    final seen = <CallSignal>[];
    DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => bob,
      selfDeviceId: 'b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )
      ..onCallSignal = (signal, from) {
        if (from == alice) seen.add(signal);
      }
      ..attach();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final conns = container.read(connectionsNotifierProvider.notifier);
    conns.debugAttachPeerjsSlot(bob);
    conns.bindNativeTransport(
      pair.$1,
      journal: MemoryJournal('a'),
      deviceId: 'a',
      devices: aliceDev,
      identities: aliceIds,
    );
    discoverySecretStore.put(alice, secret);
    discoverySecretStore.put(bob, secret);
    await pair.$1.connect(const PeerDescriptor(peerId: bob));
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (conns.canUseNative(bob)) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(conns.canUseNative(bob), isTrue);
    await conns.sendCallSignal(
      bob,
      const CallSignal(type: CallSignalType.hangup, callId: 'c-native'),
    );
    final recvDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(recvDeadline)) {
      if (seen.any((s) => s.callId == 'c-native')) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(seen.single.type, CallSignalType.hangup);
    expect(seen.single.callId, 'c-native');
    expect(conns.getConn(bob, 'reliable'), isNull);
    expect(conns.debugHasPeerjsSlot(bob), isFalse);
    expect(conns.peerjsFallbackCloseCalls, greaterThan(0));
  });

  test('PeerJS default still reports reliable from an open DataChannel', () {
    resetFlagsForTests();
    expect(isDevBareTransportRequested(), isFalse);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final conns = container.read(connectionsNotifierProvider.notifier);
    expect(conns.hasReliable('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);
  });
}
