import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/core/peer_pins.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/bare_ipc_client.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/signed_capabilities.dart';
import 'package:orbits_flutter/transport/transport_api.dart';

import '../helpers/pointycastle_ecdh.dart';

const _peerA = 'ORBIT-AAAAAAAAAAAAAAAA';
const _peerB = 'ORBIT-BBBBBBBBBBBBBBBB';

late EcKeyPairData _idA;
late EcKeyPairData _idB;
late Uint8List _spkiA;
late Uint8List _spkiB;

Future<DeviceBinding> _bind(
  String id, {
  required Uint8List spki,
  required EcKeyPairData pair,
}) {
  return issueDeviceBinding(
    identityPublicKey: spki,
    deviceId: id,
    transportPublicKey: Uint8List.fromList(
      List<int>.generate(32, (i) => i + 1),
    ),
    hypercorePublicKey: Uint8List.fromList(
      List<int>.generate(32, (i) => i + 2),
    ),
    capabilities: const ['hyperswarm-v1', 'peerjs-v4'],
    createdAt: 1,
    expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000 * 30,
    sign: (payload) async => signP256Ecdsa(pair, payload),
  );
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

  test('InProcess worklet records markAuthenticated IPC', () async {
    final pair = openInProcessIpc();
    await pair.client.request('start', {'peerId': _peerA});
    await pair.client.request('markAuthenticated', {'peerId': _peerB});
    expect(pair.worklet.methods, contains('markAuthenticated'));
    await expectLater(
      pair.client.request('markAuthenticated', {'peerId': 'https://evil'}),
      throwsStateError,
    );
    await pair.client.close();
  });

  test(
    'loopback DualStack still authenticates and records markAuthenticated',
    () async {
      setHyperswarmRollout(HyperswarmRollout.internal);
      final secret = List<int>.generate(32, (i) => 9);
      final pair = loopbackPair();
      final secrets = DiscoverySecretStore()
        ..put(_peerA, secret)
        ..put(_peerB, secret);
      await pair.$1.start(
        TransportLocalConfiguration(peerId: _peerA, discoverySecret: secret),
      );
      await pair.$2.start(
        TransportLocalConfiguration(peerId: _peerB, discoverySecret: secret),
      );
      await pair.$1.publish(await _bind('dev-a', spki: _spkiA, pair: _idA));
      await pair.$2.publish(await _bind('dev-b', spki: _spkiB, pair: _idB));
      final a = DualStackBridge(
        transport: pair.$1,
        journal: MemoryJournal('dev-a'),
        selfPeerId: () => _peerA,
        selfDeviceId: 'dev-a',
        secrets: secrets,
        isBlocked: (_) => false,
        tofuCheck: (peer, spki) async =>
            const PinCheck(status: PinStatus.newPin, fingerprint: 'test'),
        onPacket: (peer, data) async {},
      )..attach();
      final b = DualStackBridge(
        transport: pair.$2,
        journal: MemoryJournal('dev-b'),
        selfPeerId: () => _peerB,
        selfDeviceId: 'dev-b',
        secrets: secrets,
        isBlocked: (_) => false,
        tofuCheck: (peer, spki) async =>
            const PinCheck(status: PinStatus.newPin, fingerprint: 'test'),
        onPacket: (peer, data) async {},
      )..attach();
      await pair.$1.connect(const PeerDescriptor(peerId: _peerB));
      for (var i = 0; i < 80; i++) {
        if (a.authenticated.contains(_peerB) &&
            b.authenticated.contains(_peerA)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
      expect(a.authenticated.contains(_peerB), isTrue);
      expect(b.authenticated.contains(_peerA), isTrue);
      expect(pair.$1.markAuthenticatedCalls, contains(_peerB));
      expect(pair.$2.markAuthenticatedCalls, contains(_peerA));
      await a.detach();
      await b.detach();
    },
  );
}
