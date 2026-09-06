import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';

import '../helpers/signed_device_binding.dart';

class _ScriptedTransport implements OrbitsTransport {
  final _events = StreamController<TransportEvent>.broadcast();
  final decisions = <({String peerId, bool authorized})>[];

  @override
  Stream<TransportEvent> get events => _events.stream;

  void emit(TransportEvent event) => _events.add(event);

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
  Future<void> send(
    String peerId,
    TransportChannel channel,
    List<int> frame,
  ) async {}

  @override
  Future<void> sendFile(String peerId, TransportFileDescriptor file) async {}

  @override
  Future<void> suspend() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> refreshNetwork() async {}
}

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  Future<({DualStackBridge bridge, _ScriptedTransport transport})> alice({
    required DeviceBinding self,
    required DeviceBinding remote,
  }) async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final transport = _ScriptedTransport();
    final identities = TrustedIdentityStore();
    final devices = DeviceRegistry();
    trustBinding(
      identities: identities,
      devices: devices,
      binding: self,
      isSelf: true,
    );
    trustBinding(
      identities: identities,
      devices: devices,
      binding: remote,
    );
    final secrets = DiscoverySecretStore()
      ..put(self.ownerPeerId, List<int>.filled(32, 3))
      ..put(remote.ownerPeerId, List<int>.filled(32, 3));
    final bridge = DualStackBridge(
      transport: transport,
      journal: MemoryJournal('a'),
      selfPeerId: () => self.ownerPeerId,
      selfDeviceId: self.deviceId,
      secrets: secrets,
      devices: devices,
      identities: identities,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
      confirmPeerAuthorization: (peerId, {required authorized}) async {
        transport.decisions.add((peerId: peerId, authorized: authorized));
      },
    )..attach();
    return (bridge: bridge, transport: transport);
  }

  test('identity-pending does not admit until the carrier authenticates',
      () async {
    const aliceId = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bobId = 'ORBIT-BBBBBBBBBBBBBBBB';
    final self = await signedDeviceBinding(peerId: aliceId, deviceId: 'a');
    final remote = await signedDeviceBinding(peerId: bobId, deviceId: 'b');
    final pair = await alice(self: self, remote: remote);

    pair.transport.emit(
      TransportIdentityPending(
        bobId,
        remote,
        connectionNoisePublicKey: remote.transportPublicKey,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(pair.transport.decisions, isNotEmpty);
    expect(pair.transport.decisions.single.authorized, isTrue);
    expect(pair.bridge.isAuthenticated(bobId), isFalse);
    expect(pair.bridge.isNativeConnected(bobId), isFalse);

    pair.transport.emit(
      TransportAuthenticated(
        bobId,
        remote,
        connectionNoisePublicKey: remote.transportPublicKey,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(pair.bridge.isAuthenticated(bobId), isTrue);
    expect(pair.bridge.isNativeConnected(bobId), isTrue);
  });

  test('stolen ownerPeerId on identity-pending is denied', () async {
    const aliceId = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bobId = 'ORBIT-BBBBBBBBBBBBBBBB';
    final self = await signedDeviceBinding(peerId: aliceId, deviceId: 'a');
    final remote = await signedDeviceBinding(peerId: bobId, deviceId: 'b');
    final stolen = await signedDeviceBinding(
      peerId: aliceId,
      deviceId: 'stolen',
    );
    final pair = await alice(self: self, remote: remote);

    pair.transport.emit(
      TransportIdentityPending(
        bobId,
        stolen,
        connectionNoisePublicKey: stolen.transportPublicKey,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      pair.transport.decisions.any((d) => d.authorized == false),
      isTrue,
    );
    expect(pair.bridge.isAuthenticated(bobId), isFalse);
    expect(pair.bridge.isAuthenticated(aliceId), isFalse);
  });
}
