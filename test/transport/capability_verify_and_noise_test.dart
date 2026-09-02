import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/core/peer_pins.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/capabilities.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';
import 'package:orbits_flutter/transport/signed_capabilities.dart';
import 'package:orbits_flutter/transport/transport_api.dart';

import '../helpers/pointycastle_ecdh.dart';

const _peerA = 'ORBIT-AAAAAAAAAAAAAAAA';
const _peerB = 'ORBIT-BBBBBBBBBBBBBBBB';

late EcKeyPairData _idA;
late EcKeyPairData _idB;
late Uint8List _spkiA;
late Uint8List _spkiB;

final _noiseA = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));

Future<DeviceBinding> _bind(
  String id, {
  required Uint8List spki,
  required EcKeyPairData pair,
  List<int>? transportPublicKey,
}) {
  return issueDeviceBinding(
    identityPublicKey: spki,
    deviceId: id,
    transportPublicKey: Uint8List.fromList(transportPublicKey ?? _noiseA),
    hypercorePublicKey: Uint8List.fromList(
      List<int>.generate(32, (i) => i + 2),
    ),
    capabilities: const ['hyperswarm-v1', 'peerjs-v4'],
    createdAt: 1,
    expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000 * 30,
    sign: (payload) async => signP256Ecdsa(pair, payload),
  );
}

Future<PinCheck> _allowTofu(String _, List<int> __) async =>
    const PinCheck(status: PinStatus.newPin, fingerprint: 'test');

Future<void> _awaitAuth(DualStackBridge a, DualStackBridge b) async {
  for (var i = 0; i < 80; i++) {
    if (a.authenticated.contains(_peerB) && b.authenticated.contains(_peerA)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

void main() {
  setUpAll(() async {
    _idA = await generateP256EcdsaKey();
    _idB = await generateP256EcdsaKey();
    _spkiA = buildP256Spki(x: _idA.x, y: _idA.y);
    _spkiB = buildP256Spki(x: _idB.x, y: _idB.y);
  });

  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  final secret = List<int>.generate(32, (i) => 9);

  Future<(DualStackBridge, DualStackBridge)> linked({
    List<int>? Function(String peerId)? connectionNoiseFor,
    bool awaitAuth = true,
  }) async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put(_peerA, secret)
      ..put(_peerB, secret);
    DualStackBridge make(LoopbackOrbitsTransport t, String self, String device) {
      return DualStackBridge(
        transport: t,
        journal: MemoryJournal(device),
        selfPeerId: () => self,
        selfDeviceId: device,
        secrets: secrets,
        isBlocked: (_) => false,
        connectionNoiseFor: connectionNoiseFor,
        tofuCheck: _allowTofu,
        onPacket: (peer, data) async {},
      )..attach();
    }

    await pair.$1.start(
      TransportLocalConfiguration(peerId: _peerA, discoverySecret: secret),
    );
    await pair.$2.start(
      TransportLocalConfiguration(peerId: _peerB, discoverySecret: secret),
    );
    await pair.$1.publish(await _bind('dev-a', spki: _spkiA, pair: _idA));
    await pair.$2.publish(await _bind('dev-b', spki: _spkiB, pair: _idB));
    final a = make(pair.$1, _peerA, 'dev-a');
    final b = make(pair.$2, _peerB, 'dev-b');
    await pair.$1.connect(const PeerDescriptor(peerId: _peerB));
    if (awaitAuth) await _awaitAuth(a, b);
    return (a, b);
  }

  test('unsigned capability frames are not added to remoteCapabilities',
      () async {
    final (a, b) = await linked();
    final before = List<CapabilityRecord>.from(a.remoteCapabilities);
    final unsigned = CapabilityRecord(
      peerId: _peerB,
      deviceId: 'dev-b',
      capabilities: {TransportCapability.callV1},
      issuedAt: 1,
      expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000,
      signature: Uint8List(0),
      identityPublicKey: _spkiB,
    );
    await b.transport.send(
      _peerA,
      TransportChannel.control,
      jsonPayload({
        'type': 'capabilities',
        ...unsigned.toWire(),
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(
      a.remoteCapabilities.any((r) => r.signature.isEmpty),
      isFalse,
    );
    expect(a.remoteCapabilities.length, before.length);
    await a.detach();
    await b.detach();
  });

  test('signed capability frame is accepted after verify', () async {
    final (a, b) = await linked();
    final record = await issueCapabilityRecord(
      peerId: _peerB,
      deviceId: 'dev-b',
      capabilities: {TransportCapability.peerjsV4},
      issuedAt: DateTime.now().millisecondsSinceEpoch,
      expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000,
      identityPublicKey: _spkiB,
      sign: (payload) async => signP256Ecdsa(_idB, payload),
    );
    await b.transport.send(
      _peerA,
      TransportChannel.control,
      jsonPayload({
        'type': 'capabilities',
        ...record.toWire(),
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(
      a.remoteCapabilities.any(
        (r) =>
            r.deviceId == 'dev-b' &&
            listEquals(r.signature, record.signature),
      ),
      isTrue,
    );
    await a.detach();
    await b.detach();
  });

  test('loopback without connectionNoiseFor still authenticates', () async {
    final (a, b) = await linked();
    expect(a.authenticated.contains(_peerB), isTrue);
    expect(b.authenticated.contains(_peerA), isTrue);
    await a.detach();
    await b.detach();
  });

  test('DeviceBinding for identity X on Noise A is rejected on Noise B',
      () async {
    final noiseB = List<int>.generate(32, (i) => 90 + i);
    final (a, b) = await linked(
      connectionNoiseFor: (_) => noiseB,
      awaitAuth: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(a.authenticated.contains(_peerB), isFalse);
    expect(a.bindingFailures[_peerB], 'noiseMatchesBinding');
    await a.detach();
    await b.detach();
  });
}

bool listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
