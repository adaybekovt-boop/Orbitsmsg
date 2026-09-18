import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/calls/hyperswarm_signaling.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/state/calls_provider.dart';
import 'package:orbits_flutter/state/connections_notifier.dart';
import 'package:orbits_flutter/transport/dev_bare_transport.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';

import '../helpers/signed_device_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  test('incoming DualStack offer rings CallsNotifier without PeerJS', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    hydrateDevBareTransportPref(true);
    const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
    final secret = List<int>.generate(32, (i) => 11);
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
    final bobDual = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => bob,
      selfDeviceId: 'b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
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
    final calls = container.read(callsNotifierProvider.notifier);
    await pair.$2.connect(const PeerDescriptor(peerId: alice));
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (conns.canUseNative(bob) && bobDual.canUseNative(alice)) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(conns.canUseNative(bob), isTrue);
    await bobDual.sendCallSignal(
      alice,
      const CallSignal(
        type: CallSignalType.offer,
        callId: 'c-ring',
        sdp: 'offer-from-bob',
      ),
    );
    final recvDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(recvDeadline)) {
      if (container.read(callsNotifierProvider).status == CallStatus.ringing) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final state = container.read(callsNotifierProvider);
    expect(state.status, CallStatus.ringing);
    expect(state.remotePeerId, bob);
    expect(conns.lastCallSignal?.signal.callId, 'c-ring');
    expect(conns.getConn(bob, 'reliable'), isNull);
    expect(conns.debugHasPeerjsSlot(bob), isFalse);
    expect(conns.peerjsFallbackCloseCalls, greaterThan(0));
    expect(calls, isNotNull);
  });
}
