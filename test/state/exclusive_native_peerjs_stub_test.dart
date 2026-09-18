// Exclusive-native proof on REAL PeerDataConnection stubs (not the debug
// slot) with the PeerJS fallback policy ON. No hydrateDevBareTransportPref
// here except the single fail-closed control test.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/messaging/message_protocol.dart';
import 'package:orbits_flutter/peer/peerjs_client.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/state/calls_provider.dart';
import 'package:orbits_flutter/state/connections_notifier.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/transport/dev_bare_transport.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';

import '../helpers/signed_device_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OrbitsDatabase database;
  setUp(() async {
    resetFlagsForTests();
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 3 + 1) & 0xff));
  });
  tearDown(() async {
    discoverySecretStore
      ..clearMemory()
      ..writeSnapshot = null;
    resetFlagsForTests();
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  test(
      'native auth closes PeerJS stub; no send/onData after canUseNative; '
      'one handshake', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    expect(isPeerjsFallbackEnabled(), isTrue);
    expect(isDevBareTransportRequested(), isFalse);

    const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
    final secret = List<int>.generate(32, (i) => 21);
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
    final bobBridge = DualStackBridge(
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
    addTearDown(bobBridge.detach);

    var inboundDispatched = 0;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final conns = container.read(connectionsNotifierProvider.notifier);
    conns.bindMessaging(
      MessagingBridge(
        pushInbound: (_, __) async {
          inboundDispatched += 1;
          return InboundPersistResult.committed;
        },
        patchMessage: (_, __, ___) {},
        queueAckStatus: (_, __) {},
        flushOutboxForPeer: (_) async {},
        loadPendingForPeer: (_) async {},
        applyTyping: (_, __) {},
      ),
    );

    // Closed stub: no PeerJS-open handshake work, no sends.
    final stub = PeerDataConnection.stub(peer: bob, initiallyOpen: false);
    await conns.attachConn(stub, 'reliable');
    expect(conns.getConn(bob, 'reliable'), same(stub));
    expect(stub.debugSent, isEmpty);

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
      if (conns.canUseNative(bob) && stub.closed) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(conns.canUseNative(bob), isTrue);
    expect(stub.closed, isTrue);
    expect(conns.getConn(bob, 'reliable'), isNull);
    expect(conns.peerjsFallbackCloseCalls, 1);
    expect(conns.wire.debugHandshakeStarts, 1);

    // wireHello on an authenticated peer routes native (transport.send)
    // with no X3DH wire session needed; the PeerJS stub stays silent.
    expect(
      await conns.sendEncrypted(bob, {'type': 'wireHello', 'v': 4}),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(stub.debugSent, isEmpty);

    stub.debugEmitData({'type': 'msg', 'id': 'no-dispatch', 'text': 'x'});
    await Future<void>.delayed(Duration.zero);
    expect(inboundDispatched, 0);
    // Settle unawaited registry writes before the container/DB tear down.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('native throw does not send PeerJS when fallback is allowed', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    expect(isPeerjsFallbackEnabled(), isTrue);
    expect(isDevBareTransportRequested(), isFalse);

    const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
    final secret = List<int>.generate(32, (i) => 7);
    final transport = _ThrowingTransport();
    final secrets = DiscoverySecretStore()
      ..put(alice, secret)
      ..put(bob, secret);
    final bindA = await signedDeviceBinding(peerId: alice, deviceId: 'a');
    final bindB = await signedDeviceBinding(peerId: bob, deviceId: 'b');
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
    final bridge = DualStackBridge(
      transport: transport,
      journal: MemoryJournal('a'),
      selfPeerId: () => alice,
      selfDeviceId: 'a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final conns = container.read(connectionsNotifierProvider.notifier);
    final stub = PeerDataConnection.stub(peer: bob, initiallyOpen: true);
    await conns.attachConn(stub, 'reliable');
    conns.debugBindNativeBridge(bridge);
    bridge.connected.add(bob);
    bridge.authenticated.add(bob);
    expect(conns.canUseNative(bob), isTrue);
    expect(conns.getConn(bob, 'reliable'), same(stub));

    // wireHello on an authenticated peer goes straight to transport.send,
    // which throws here — deterministically, with no 8s wire wait.
    transport.throwOnSend = true;
    final sentBefore = stub.debugSent.length;
    expect(
      await conns.sendEncrypted(bob, {'type': 'wireHello', 'v': 4}),
      isFalse,
    );
    expect(stub.debugSent.length, sentBefore);
    expect(bridge.lastReplicationError, isNotEmpty);
    expect(conns.canUseNative(bob), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await bridge.detach();
  });

  test('inbound PeerJS onCall while canUseNative closes and does not ring',
      () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    expect(isPeerjsFallbackEnabled(), isTrue);
    expect(isDevBareTransportRequested(), isFalse);

    const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
    final secret = List<int>.generate(32, (i) => 3);
    final transport = _ThrowingTransport();
    final secrets = DiscoverySecretStore()
      ..put(alice, secret)
      ..put(bob, secret);
    final bridge = DualStackBridge(
      transport: transport,
      journal: MemoryJournal('a'),
      selfPeerId: () => alice,
      selfDeviceId: 'a',
      secrets: secrets,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final conns = container.read(connectionsNotifierProvider.notifier);
    final calls = container.read(callsNotifierProvider.notifier);
    conns.debugBindNativeBridge(bridge);
    bridge.connected.add(bob);
    bridge.authenticated.add(bob);
    expect(conns.canUseNative(bob), isTrue);
    // Let the CallsNotifier's connections listener observe the state.
    await Future<void>.delayed(Duration.zero);

    final media = PeerMediaConnection.stub(peer: bob);
    calls.handlePeerjsInboundCall(media);
    await Future<void>.delayed(Duration.zero);

    expect(media.closed, isTrue);
    expect(
      container.read(callsNotifierProvider).status,
      CallStatus.idle,
    );
    expect(
      container.read(callsNotifierProvider).remotePeerId,
      isNull,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await bridge.detach();
  });
}

class _ThrowingTransport implements OrbitsTransport {
  final _controller = StreamController<TransportEvent>.broadcast();
  bool throwOnSend = false;

  @override
  Stream<TransportEvent> get events => _controller.stream;

  @override
  Future<void> start(TransportLocalConfiguration config) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> publish(DeviceBinding binding) async {}

  @override
  Future<void> unpublish() async {}

  @override
  Future<void> connect(PeerDescriptor peer) async {}

  @override
  Future<void> disconnect(String peerId) async {}

  @override
  Future<void> authorizePeer(String peerId, {required bool authorized}) async {}

  @override
  Future<void> send(
    String peerId,
    TransportChannel channel,
    List<int> frame,
  ) async {
    if (throwOnSend) throw StateError('native-send-failed');
  }

  @override
  Future<void> sendFile(String peerId, TransportFileDescriptor file) async {}

  @override
  Future<void> suspend() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> refreshNetwork() async {}
}
