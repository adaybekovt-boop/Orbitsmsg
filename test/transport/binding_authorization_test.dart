import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';

import '../helpers/signed_device_binding.dart';

class _FakeTransport implements OrbitsTransport {
  final _controller = StreamControllerish();
  final sent = <({String peer, TransportChannel channel, List<int> bytes})>[];
  final disconnected = <String>[];

  @override
  Stream<TransportEvent> get events => _controller.stream;

  void emit(TransportEvent event) => _controller.add(event);

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
  Future<void> disconnect(String peerId) async {
    disconnected.add(peerId);
  }

  @override
  Future<void> send(
    String peerId,
    TransportChannel channel,
    List<int> frame,
  ) async {
    sent.add((peer: peerId, channel: channel, bytes: frame));
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

class StreamControllerish {
  final _ctrl = StreamController<TransportEvent>.broadcast();
  Stream<TransportEvent> get stream => _ctrl.stream;
  void add(TransportEvent event) => _ctrl.add(event);
}

const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
const carol = 'ORBIT-CCCCCCCCCCCCCCCC';

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  Future<DualStackBridge> open({
    required _FakeTransport transport,
    DeviceRegistry? devices,
    TrustedIdentityStore? identities,
  }) async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final dual = DualStackBridge(
      transport: transport,
      journal: MemoryJournal('dev-a'),
      selfPeerId: () => alice,
      selfDeviceId: 'dev-a',
      secrets: DiscoverySecretStore()
        ..put(alice, List<int>.filled(32, 1))
        ..put(bob, List<int>.filled(32, 1)),
      devices: devices ?? DeviceRegistry(),
      identities: identities ?? TrustedIdentityStore(),
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    return dual;
  }

  Future<void> present(
    _FakeTransport transport,
    DeviceBinding binding, {
    String? transportPeerId,
    List<int>? noise,
  }) async {
    transport.emit(
      TransportAuthenticated(
        transportPeerId ?? binding.ownerPeerId,
        binding,
        connectionNoisePublicKey: noise ?? binding.transportPublicKey,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  test('F-01 attacker-signed binding with stolen ownerPeerId is rejected', () async {
    final transport = _FakeTransport();
    final devices = DeviceRegistry();
    final identities = TrustedIdentityStore();
    final victim = await signedIdentity(bob);
    final victimBind = await signedDeviceBinding(
      peerId: bob,
      deviceId: 'dev-b',
      identity: victim,
    );
    trustBinding(identities: identities, devices: devices, binding: victimBind);

    final dual = await open(
      transport: transport,
      devices: devices,
      identities: identities,
    );
    final attacker = await signedIdentity(carol);
    final stolen = await signedDeviceBinding(
      peerId: bob,
      deviceId: 'dev-attacker',
      identity: attacker,
    );
    await present(transport, stolen);
    expect(dual.isAuthenticated(bob), isFalse);
    expect(dual.isNativeConnected(bob), isFalse);
    expect(transport.disconnected, contains(bob));
    expect(transport.sent, isEmpty);
    expect(dual.isOwnDevice(bob), isFalse);
    await dual.detach();
  });

  test('F-01 claiming local ownerPeerId does not grant own-device', () async {
    final transport = _FakeTransport();
    final devices = DeviceRegistry();
    final identities = TrustedIdentityStore();
    final self = await signedIdentity(alice);
    identities.trust(
      peerId: alice,
      identityPublicKey: self.spki,
      isSelf: true,
    );
    final dual = await open(
      transport: transport,
      devices: devices,
      identities: identities,
    );
    final attacker = await signedIdentity(carol);
    final claim = await signedDeviceBinding(
      peerId: alice,
      deviceId: 'dev-attacker',
      identity: attacker,
    );
    await present(transport, claim, transportPeerId: alice);
    expect(dual.isAuthenticated(alice), isFalse);
    expect(dual.isOwnDevice(alice), isFalse);
    expect(transport.disconnected, contains(alice));
    expect(transport.sent, isEmpty);
    await dual.detach();
  });

  test('F-01 valid signature with unknown identity key is rejected', () async {
    final transport = _FakeTransport();
    final dual = await open(transport: transport);
    final unknown = await signedDeviceBinding(peerId: bob, deviceId: 'dev-b');
    await present(transport, unknown);
    expect(dual.isAuthenticated(bob), isFalse);
    expect(transport.disconnected, contains(bob));
    expect(transport.sent, isEmpty);
    await dual.detach();
  });

  test('F-01 trusted identity with unknown deviceId is rejected', () async {
    final transport = _FakeTransport();
    final devices = DeviceRegistry();
    final identities = TrustedIdentityStore();
    final bobId = await signedIdentity(bob);
    identities.trust(peerId: bob, identityPublicKey: bobId.spki);
    final dual = await open(
      transport: transport,
      devices: devices,
      identities: identities,
    );
    final bind = await signedDeviceBinding(
      peerId: bob,
      deviceId: 'never-registered',
      identity: bobId,
    );
    await present(transport, bind);
    expect(dual.isAuthenticated(bob), isFalse);
    expect(transport.disconnected, contains(bob));
    await dual.detach();
  });

  test('F-01 trusted identity and device with wrong Noise key is rejected', () async {
    final transport = _FakeTransport();
    final devices = DeviceRegistry();
    final identities = TrustedIdentityStore();
    final bind = await signedDeviceBinding(peerId: bob, deviceId: 'dev-b');
    trustBinding(identities: identities, devices: devices, binding: bind);
    final dual = await open(
      transport: transport,
      devices: devices,
      identities: identities,
    );
    await present(transport, bind, noise: List<int>.filled(32, 9));
    expect(dual.isAuthenticated(bob), isFalse);
    expect(transport.disconnected, contains(bob));
    await dual.detach();
  });

  test('F-01 revoked binding cannot be reused', () async {
    final transport = _FakeTransport();
    final devices = DeviceRegistry();
    final identities = TrustedIdentityStore();
    final bind = await signedDeviceBinding(peerId: bob, deviceId: 'dev-b');
    trustBinding(identities: identities, devices: devices, binding: bind);
    devices.revoke('dev-b');
    final dual = await open(
      transport: transport,
      devices: devices,
      identities: identities,
    );
    await present(transport, bind);
    expect(dual.isAuthenticated(bob), isFalse);
    expect(transport.disconnected, contains(bob));
    await dual.detach();
  });

  test('F-01 expired binding is rejected', () async {
    final transport = _FakeTransport();
    final devices = DeviceRegistry();
    final identities = TrustedIdentityStore();
    final bind = await signedDeviceBinding(
      peerId: bob,
      deviceId: 'dev-b',
      createdAt: 1,
      expiresAt: 2,
    );
    trustBinding(identities: identities, devices: devices, binding: bind);
    final dual = await open(
      transport: transport,
      devices: devices,
      identities: identities,
    );
    await present(transport, bind);
    expect(dual.isAuthenticated(bob), isFalse);
    await dual.detach();
  });

  test('F-01 trusted contact authenticates without own-device privileges', () async {
    final transport = _FakeTransport();
    final devices = DeviceRegistry();
    final identities = TrustedIdentityStore();
    final bind = await signedDeviceBinding(peerId: bob, deviceId: 'dev-b');
    trustBinding(identities: identities, devices: devices, binding: bind);
    final dual = await open(
      transport: transport,
      devices: devices,
      identities: identities,
    );
    await present(transport, bind);
    expect(dual.isAuthenticated(bob), isTrue);
    expect(dual.isNativeConnected(bob), isTrue);
    expect(dual.isOwnDevice(bob), isFalse);
    dual.appendAndReplicate(
      JournalRecord(
        seq: 1,
        writerDeviceId: 'dev-a',
        kind: ReplicationEventKind.deviceAuthorized,
        fields: <String, Object?>{
          'deviceId': 'phone-2',
          'ownerPeerId': alice,
          'audience': 'owner-devices',
        },
      ),
    );
    expect(
      transport.sent.where((s) => s.channel == TransportChannel.replication),
      isEmpty,
    );
    await dual.detach();
  });

  test('F-01 owner second device requires registry + matching identity', () async {
    final transport = _FakeTransport();
    final devices = DeviceRegistry();
    final identities = TrustedIdentityStore();
    final owner = await signedIdentity(alice);
    identities.trust(
      peerId: alice,
      identityPublicKey: owner.spki,
      isSelf: true,
    );
    final phone2 = await signedDeviceBinding(
      peerId: alice,
      deviceId: 'phone-2',
      identity: owner,
      transportPublicKey: List<int>.generate(32, (i) => i + 20),
    );
    devices.authorize(
      AuthorizedDevice(
        deviceId: 'phone-2',
        transportPublicKey: phone2.transportPublicKey,
        hypercorePublicKey: phone2.hypercorePublicKey,
        name: 'phone-2',
        kind: 'own',
        createdAt: phone2.createdAt,
        status: DeviceStatus.active,
        ownerPeerId: alice,
        transportPeerId: 'ORBIT-A2A2A2A2A2A2A2A2',
      ),
    );
    final dual = await open(
      transport: transport,
      devices: devices,
      identities: identities,
    );
    await present(
      transport,
      phone2,
      transportPeerId: 'ORBIT-A2A2A2A2A2A2A2A2',
    );
    expect(dual.isAuthenticated(alice), isTrue);
    expect(dual.isOwnDevice(alice), isTrue);
    expect(dual.isOwnDevice('ORBIT-A2A2A2A2A2A2A2A2'), isTrue);
    await dual.detach();
  });

  test('F-01 first connect of unknown device is not auto-authorized', () async {
    final transport = _FakeTransport();
    final devices = DeviceRegistry();
    final identities = TrustedIdentityStore();
    final owner = await signedIdentity(alice);
    identities.trust(
      peerId: alice,
      identityPublicKey: owner.spki,
      isSelf: true,
    );
    final dual = await open(
      transport: transport,
      devices: devices,
      identities: identities,
    );
    final stranger = await signedDeviceBinding(
      peerId: alice,
      deviceId: 'brand-new',
      identity: owner,
    );
    await present(transport, stranger, transportPeerId: alice);
    expect(dual.isAuthenticated(alice), isFalse);
    expect(devices.acceptsWriter('brand-new'), isFalse);
    expect(dual.isOwnDevice(alice), isFalse);
    await dual.detach();
  });
}
