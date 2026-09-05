import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';

import '../helpers/pointycastle_ecdh.dart';
import '../helpers/signed_device_binding.dart';

class _FakeTransport implements OrbitsTransport {
  final _controller = StreamController<TransportEvent>.broadcast();
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
  Future<void> send(String peerId, TransportChannel channel, List<int> frame) async {
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

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  Future<DualStackBridge> bridge(
    _FakeTransport transport, {
    DeviceRegistry? devices,
    TrustedIdentityStore? identities,
  }) async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', List<int>.filled(32, 1))
      ..put('ORBIT-BBBBBBBBBBBBBBBB', List<int>.filled(32, 1));
    final dual = DualStackBridge(
      transport: transport,
      journal: MemoryJournal('dev-a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'dev-a',
      secrets: secrets,
      devices: devices ?? DeviceRegistry(),
      identities: identities ?? TrustedIdentityStore(),
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    return dual;
  }

  test('wrong Noise key, expired, forged, replay, substitution, revoke', () async {
    final transport = _FakeTransport();
    final devices = DeviceRegistry();
    final dual = await bridge(transport, devices: devices);
    final good = await signedDeviceBinding(
      peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      deviceId: 'dev-b',
    );

    transport.emit(
      TransportAuthenticated(
        'ORBIT-BBBBBBBBBBBBBBBB',
        good,
        connectionNoisePublicKey: List<int>.filled(32, 9),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(dual.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);
    expect(transport.disconnected, contains('ORBIT-BBBBBBBBBBBBBBBB'));
    expect(transport.sent, isEmpty);

    final expired = await signedDeviceBinding(
      peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      deviceId: 'dev-b-exp',
      createdAt: 1,
      expiresAt: 2,
    );
    transport.emit(
      TransportAuthenticated(
        'ORBIT-BBBBBBBBBBBBBBBB',
        expired,
        connectionNoisePublicKey: expired.transportPublicKey,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(dual.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);

    final pair = await generateP256EcdsaKey();
    final forged = DeviceBinding(
      version: kDeviceBindingVersion,
      identityPublicKey: buildP256Spki(x: pair.x, y: pair.y),
      deviceId: 'dev-forged',
      transportPublicKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 3)),
      hypercorePublicKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 4)),
      capabilities: const ['hyperswarm-v1'],
      createdAt: DateTime.now().millisecondsSinceEpoch,
      expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
      signatureByIdentityKey: Uint8List.fromList(List<int>.filled(64, 7)),
      ownerPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
    );
    transport.emit(
      TransportAuthenticated(
        'ORBIT-BBBBBBBBBBBBBBBB',
        forged,
        connectionNoisePublicKey: forged.transportPublicKey,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(dual.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);

    final ok = await signedDeviceBinding(
      peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      deviceId: 'dev-ok',
    );
    final identities = TrustedIdentityStore();
    trustBinding(identities: identities, devices: devices, binding: ok);
    await dual.detach();
    final trusted = await bridge(transport, devices: devices, identities: identities);
    transport.emit(
      TransportAuthenticated(
        'ORBIT-BBBBBBBBBBBBBBBB',
        ok,
        connectionNoisePublicKey: ok.transportPublicKey,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(trusted.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    expect(trusted.isNativeConnected('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);

    transport.emit(
      TransportAuthenticated(
        'ORBIT-CCCCCCCCCCCCCCCC',
        ok,
        connectionNoisePublicKey: ok.transportPublicKey,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(trusted.isAuthenticated('ORBIT-CCCCCCCCCCCCCCCC'), isFalse);
    expect(transport.disconnected, contains('ORBIT-CCCCCCCCCCCCCCCC'));

    final swapped = DeviceBinding(
      version: ok.version,
      identityPublicKey: ok.identityPublicKey,
      deviceId: ok.deviceId,
      transportPublicKey: ok.transportPublicKey,
      hypercorePublicKey: ok.hypercorePublicKey,
      capabilities: ok.capabilities,
      createdAt: ok.createdAt,
      expiresAt: ok.expiresAt,
      signatureByIdentityKey: ok.signatureByIdentityKey,
      ownerPeerId: 'ORBIT-CCCCCCCCCCCCCCCC',
    );
    transport.emit(
      TransportAuthenticated(
        'ORBIT-CCCCCCCCCCCCCCCC',
        swapped,
        connectionNoisePublicKey: swapped.transportPublicKey,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(trusted.isAuthenticated('ORBIT-CCCCCCCCCCCCCCCC'), isFalse);

    devices.revoke('dev-ok');
    await trusted.detach();
    final afterRevoke = await bridge(
      transport,
      devices: devices,
      identities: identities,
    );
    transport.emit(
      TransportAuthenticated(
        'ORBIT-BBBBBBBBBBBBBBBB',
        ok,
        connectionNoisePublicKey: ok.transportPublicKey,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(afterRevoke.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);
    await afterRevoke.detach();
  });
}
