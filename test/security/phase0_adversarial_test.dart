// Behavioral Phase 0 adversarial coverage. Drives DualStack + loopback
// objects — not File.readAsStringSync source scans.
//
// Call-signal predicates live in hyperswarm_signaling.dart and are unit-
// tested in test/calls/call_sdp_and_session_test.dart. This file wires
// those predicates through a real DualStack pair (and a third peer).

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/calls/hyperswarm_signaling.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/core/peer_pins.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/capabilities.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/hello_capabilities.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';
import 'package:orbits_flutter/transport/signed_capabilities.dart';
import 'package:orbits_flutter/transport/transport_api.dart';

import '../helpers/pointycastle_ecdh.dart';

const _peerA = 'ORBIT-AAAAAAAAAAAAAAAA';
const _peerB = 'ORBIT-BBBBBBBBBBBBBBBB';
const _peerC = 'ORBIT-CCCCCCCCCCCCCCCC';

const _realSdp =
    'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n';

final _bindTransport = List<int>.generate(32, (i) => i + 1);

late EcKeyPairData _idA;
late EcKeyPairData _idB;
late EcKeyPairData _idC;
late Uint8List _spkiA;
late Uint8List _spkiB;
late Uint8List _spkiC;

Future<DeviceBinding> _bind(
  String id, {
  required Uint8List spki,
  required EcKeyPairData pair,
  List<int>? transportPublicKey,
  List<String> capabilities = const ['hyperswarm-v1', 'peerjs-v4'],
  int createdAt = 1,
  int? expiresAt,
}) {
  return issueDeviceBinding(
    identityPublicKey: spki,
    deviceId: id,
    transportPublicKey: Uint8List.fromList(
      transportPublicKey ?? _bindTransport,
    ),
    hypercorePublicKey: Uint8List.fromList(
      List<int>.generate(32, (i) => i + 2),
    ),
    capabilities: capabilities,
    createdAt: createdAt,
    expiresAt: expiresAt ??
        DateTime.now().millisecondsSinceEpoch + 86400000 * 30,
    sign: (payload) async => signP256Ecdsa(pair, payload),
  );
}

Future<PinCheck> _allowTofu(String _, List<int> __) async =>
    const PinCheck(status: PinStatus.newPin, fingerprint: 'test');

Future<void> _pump([int ms = 40]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

Future<void> _awaitAuth(DualStackBridge a, DualStackBridge b) async {
  for (var i = 0; i < 80; i++) {
    if (a.authenticated.contains(_peerB) && b.authenticated.contains(_peerA)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

DualStackBridge _bridge({
  required LoopbackOrbitsTransport transport,
  required String self,
  required String device,
  required DiscoverySecretStore secrets,
  required Uint8List spki,
  Future<PinCheck> Function(String peerId, List<int> identitySpki)? tofuCheck,
  List<int>? Function(String peerId)? connectionNoiseFor,
  CapabilityRecord? localCapabilities,
}) {
  return DualStackBridge(
    transport: transport,
    journal: MemoryJournal(device),
    selfPeerId: () => self,
    selfDeviceId: device,
    secrets: secrets,
    isBlocked: (_) => false,
    tofuCheck: tofuCheck ?? _allowTofu,
    connectionNoiseFor: connectionNoiseFor,
    ownIdentityPublicKey: () => spki,
    localCapabilities: localCapabilities,
    onPacket: (_, __) async {},
  )..attach();
}

Future<(DualStackBridge, DualStackBridge)> _linked({
  Future<PinCheck> Function(String peerId, List<int> identitySpki)? tofuCheck,
  List<int>? Function(String peerId)? connectionNoiseFor,
  bool awaitAuth = true,
  CapabilityRecord? capsA,
  CapabilityRecord? capsB,
}) async {
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
  final a = _bridge(
    transport: pair.$1,
    self: _peerA,
    device: 'dev-a',
    secrets: secrets,
    spki: _spkiA,
    tofuCheck: tofuCheck,
    connectionNoiseFor: connectionNoiseFor,
    localCapabilities: capsA,
  );
  final b = _bridge(
    transport: pair.$2,
    self: _peerB,
    device: 'dev-b',
    secrets: secrets,
    spki: _spkiB,
    tofuCheck: tofuCheck,
    connectionNoiseFor: connectionNoiseFor,
    localCapabilities: capsB,
  );
  await pair.$1.connect(const PeerDescriptor(peerId: _peerB));
  if (awaitAuth) {
    await _awaitAuth(a, b);
  } else {
    await _pump(80);
  }
  return (a, b);
}

Future<(DualStackBridge, DualStackBridge, DualStackBridge)>
_linkedTriple() async {
  setHyperswarmRollout(HyperswarmRollout.internal);
  final secret = List<int>.generate(32, (i) => 9);
  final hub = LoopbackHub();
  final tA = LoopbackOrbitsTransport(hub: hub);
  final tB = LoopbackOrbitsTransport(hub: hub);
  final tC = LoopbackOrbitsTransport(hub: hub);
  final secrets = DiscoverySecretStore()
    ..put(_peerA, secret)
    ..put(_peerB, secret)
    ..put(_peerC, secret);
  await tA.start(
    TransportLocalConfiguration(peerId: _peerA, discoverySecret: secret),
  );
  await tB.start(
    TransportLocalConfiguration(peerId: _peerB, discoverySecret: secret),
  );
  await tC.start(
    TransportLocalConfiguration(peerId: _peerC, discoverySecret: secret),
  );
  await tA.publish(await _bind('dev-a', spki: _spkiA, pair: _idA));
  await tB.publish(await _bind('dev-b', spki: _spkiB, pair: _idB));
  await tC.publish(await _bind('dev-c', spki: _spkiC, pair: _idC));
  final a = _bridge(
    transport: tA,
    self: _peerA,
    device: 'dev-a',
    secrets: secrets,
    spki: _spkiA,
  );
  final b = _bridge(
    transport: tB,
    self: _peerB,
    device: 'dev-b',
    secrets: secrets,
    spki: _spkiB,
  );
  final c = _bridge(
    transport: tC,
    self: _peerC,
    device: 'dev-c',
    secrets: secrets,
    spki: _spkiC,
  );
  await tA.connect(const PeerDescriptor(peerId: _peerB));
  await tC.connect(const PeerDescriptor(peerId: _peerB));
  for (var i = 0; i < 80; i++) {
    if (a.authenticated.contains(_peerB) &&
        b.authenticated.contains(_peerA) &&
        b.authenticated.contains(_peerC) &&
        c.authenticated.contains(_peerB)) {
      return (a, b, c);
    }
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
  throw StateError(
    'triple did not authenticate: '
    'a=${a.authenticated} b=${b.authenticated} c=${c.authenticated}',
  );
}

void main() {
  setUpAll(() async {
    _idA = await generateP256EcdsaKey();
    _idB = await generateP256EcdsaKey();
    _idC = await generateP256EcdsaKey();
    _spkiA = buildP256Spki(x: _idA.x, y: _idA.y);
    _spkiB = buildP256Spki(x: _idB.x, y: _idB.y);
    _spkiC = buildP256Spki(x: _idC.x, y: _idC.y);
  });

  setUp(() {
    resetFlagsForTests();
    remoteCapabilityCache.clear();
  });
  tearDown(() {
    resetFlagsForTests();
    remoteCapabilityCache.clear();
  });

  test('DeviceBinding from a different Noise connection is rejected', () async {
    var noise = List<int>.from(_bindTransport);
    final (a, b) = await _linked(connectionNoiseFor: (_) => noise);
    expect(a.authenticated.contains(_peerB), isTrue);
    expect(b.authenticated.contains(_peerA), isTrue);

    await a.transport.disconnect(_peerB);
    await _pump();
    expect(a.authenticated.contains(_peerB), isFalse);
    expect(a.remoteBindings.containsKey(_peerB), isFalse);

    noise = List<int>.generate(32, (i) => 77);
    await a.transport.connect(const PeerDescriptor(peerId: _peerB));
    await _pump(80);
    expect(a.authenticated.contains(_peerB), isFalse);
    expect(a.canUseNative(_peerB), isFalse);
    expect(a.bindingFailures[_peerB], 'noiseMatchesBinding');
    expect(a.remoteBindings[_peerB], isNull);
    await a.detach();
    await b.detach();
  });

  test('TOFU pin-store throw fails closed (no auth, no binding)', () async {
    final (a, b) = await _linked(
      awaitAuth: false,
      tofuCheck: (peer, spki) async {
        throw StateError('pin-store unavailable');
      },
    );
    expect(a.authenticated.contains(_peerB), isFalse);
    expect(b.authenticated.contains(_peerA), isFalse);
    expect(a.canUseNative(_peerB), isFalse);
    expect(a.remoteBindings[_peerB], isNull);
    expect(
      a.bindingFailures[_peerB],
      anyOf('tofuDoesNotConflict', 'signedByKnownIdentity'),
    );
    await a.detach();
    await b.detach();
  });

  test(
    'unsigned capability is not cached and does not advertise call-v1',
    () async {
      final pair = await generateP256EcdsaKey();
      final spki = buildP256Spki(x: pair.x, y: pair.y);
      final unsigned = CapabilityRecord(
        peerId: _peerB,
        deviceId: 'dev-b',
        capabilities: {
          TransportCapability.hyperswarmV1,
          TransportCapability.callV1,
        },
        issuedAt: 1,
        expiresAt: 10,
        signature: Uint8List(0),
        identityPublicKey: spki,
      );
      expect(await verifyCapabilityRecord(unsigned), isFalse);

      setHyperswarmRollout(HyperswarmRollout.internal);
      final (a, b) = await _linked();
      expect(a.remoteUnderstandsNativeCall(_peerB), isFalse);

      await b.transport.send(
        _peerA,
        TransportChannel.control,
        jsonPayload({
          'type': 'wireHello',
          'v': 3,
          'peerId': _peerB,
          'caps': unsigned.toWire(),
        }),
      );
      await _pump();
      expect(remoteCapabilityCache.get(_peerB), isNull);
      expect(a.remoteUnderstandsNativeCall(_peerB), isFalse);

      await b.transport.send(
        _peerA,
        TransportChannel.control,
        jsonPayload({'type': 'capabilities', ...unsigned.toWire()}),
      );
      await _pump();
      expect(a.remoteUnderstandsNativeCall(_peerB), isFalse);
      expect(
        a.remoteCapabilities.any(
          (r) => r.deviceId == 'dev-b' && r.signature.isEmpty,
        ),
        isFalse,
      );
      await a.detach();
      await b.detach();
    },
  );

  test('wall-clock expired capability is rejected', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = await issueCapabilityRecord(
      peerId: _peerB,
      deviceId: 'dev-b',
      capabilities: {
        TransportCapability.hyperswarmV1,
        TransportCapability.callV1,
      },
      issuedAt: now - 86_400_000,
      expiresAt: now - 1_000,
      identityPublicKey: _spkiB,
      sign: (payload) async => signP256Ecdsa(_idB, payload),
    );
    expect(await verifyCapabilityRecord(expired), isFalse);

    final remembered = await rememberHelloCapabilities(_peerB, {
      'type': 'wireHello',
      'v': 3,
      'peerId': _peerB,
      'caps': expired.toWire(),
    });
    expect(remembered, isNull);
    expect(remoteCapabilityCache.get(_peerB), isNull);
  });

  test(
    'cached call-v1 without a native carrier leaves canUseNative false',
    () async {
      setHyperswarmRollout(HyperswarmRollout.internal);
      final secret = List<int>.generate(32, (i) => 9);
      final t = LoopbackOrbitsTransport();
      await t.start(
        TransportLocalConfiguration(peerId: _peerA, discoverySecret: secret),
      );
      final a = _bridge(
        transport: t,
        self: _peerA,
        device: 'dev-a',
        secrets: DiscoverySecretStore()..put(_peerB, secret),
        spki: _spkiA,
      );
      final cached = await issueCapabilityRecord(
        peerId: _peerB,
        deviceId: 'dev-b',
        capabilities: {
          TransportCapability.hyperswarmV1,
          TransportCapability.callV1,
        },
        issuedAt: 1,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 86_400_000,
        identityPublicKey: _spkiB,
        sign: (payload) async => signP256Ecdsa(_idB, payload),
      );
      remoteCapabilityCache.put(_peerB, cached);

      expect(a.remoteUnderstandsNativeCall(_peerB), isTrue);
      expect(a.isNativeConnected(_peerB), isFalse);
      expect(a.authenticated.contains(_peerB), isFalse);
      expect(a.canUseNative(_peerB), isFalse);
      expect(
        shouldCloseLeftoverPeerJsCall(
          canUseNative: a.canUseNative(_peerB),
          remoteUnderstandsNativeCall: a.remoteUnderstandsNativeCall(_peerB),
          nativeSessionExists: false,
        ),
        isFalse,
      );

      CallSignal? seen;
      a.onCallSignal = (signal, from) => seen = signal;
      await a.sendCallSignal(
        _peerB,
        const CallSignal(
          type: CallSignalType.offer,
          callId: 'c-cached',
          sdp: _realSdp,
        ),
      );
      await _pump();
      expect(seen, isNull);
      expect(t.sentPeerIds, isEmpty);
      await a.detach();
    },
  );

  test(
    'application frames are queued until DualStack DeviceBinding auth',
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
      final seen = <Object?>[];
      DualStackBridge make(LoopbackOrbitsTransport t, String self, String d) {
        return DualStackBridge(
          transport: t,
          journal: MemoryJournal(d),
          selfPeerId: () => self,
          selfDeviceId: d,
          secrets: secrets,
          isBlocked: (_) => false,
          tofuCheck: (peer, spki) async {
            await Future<void>.delayed(const Duration(milliseconds: 80));
            return _allowTofu(peer, spki);
          },
          onPacket: (peer, data) async => seen.add(data),
        )..attach();
      }

      final a = make(pair.$1, _peerA, 'dev-a');
      final b = make(pair.$2, _peerB, 'dev-b');
      await pair.$1.connect(const PeerDescriptor(peerId: _peerB));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(a.isNativeConnected(_peerB), isTrue);
      expect(b.authenticated.contains(_peerA), isFalse);

      await a.transport.send(
        _peerB,
        TransportChannel.message,
        jsonPayload({'type': 'wireHello', 'v': 4, 'preAuth': true}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen.whereType<Map>().any((m) => m['preAuth'] == true), isFalse);

      await _awaitAuth(a, b);
      await _pump();
      expect(seen.whereType<Map>().any((m) => m['preAuth'] == true), isTrue);
      await a.detach();
      await b.detach();
    },
  );

  test(
    'hangup and ICE from a foreign peer do not close the A-B session',
    () async {
      final (a, b, c) = await _linkedTriple();
      final session = NativeCallSession(send: (_) async {});
      session.callId = 'c1';
      final applied = <CallSignal>[];
      b.onCallSignal = (signal, from) {
        if (!acceptInboundCallSignal(
          from: from,
          signal: signal,
          activeRemotePeerId: _peerA,
          sessionCallId: session.callId,
          sessionActive: true,
        )) {
          return;
        }
        applied.add(signal);
        session.applyRemote(signal);
      };

      await c.sendCallSignal(
        _peerB,
        const CallSignal(type: CallSignalType.hangup, callId: 'c1'),
      );
      await c.sendCallSignal(
        _peerB,
        const CallSignal(
          type: CallSignalType.iceCandidate,
          callId: 'c1',
          candidate: {'candidate': '1.1.1.1'},
        ),
      );
      await _pump();
      expect(session.closed, isFalse);
      expect(session.remoteIce, isEmpty);
      expect(applied, isEmpty);

      await a.sendCallSignal(
        _peerB,
        const CallSignal(type: CallSignalType.hangup, callId: 'c1'),
      );
      await _pump();
      expect(applied, hasLength(1));
      expect(applied.single.type, CallSignalType.hangup);
      expect(session.closed, isTrue);
      await a.detach();
      await b.detach();
      await c.detach();
    },
  );

  test(
    'stale callId ICE and hangup do not apply to the live session',
    () async {
      final (a, b) = await _linked();
      final session = NativeCallSession(send: (_) async {});
      session.callId = 'c-live';
      b.onCallSignal = (signal, from) {
        if (!acceptInboundCallSignal(
          from: from,
          signal: signal,
          activeRemotePeerId: _peerA,
          sessionCallId: session.callId,
          sessionActive: true,
        )) {
          return;
        }
        session.applyRemote(signal);
      };

      await a.sendCallSignal(
        _peerB,
        const CallSignal(
          type: CallSignalType.iceCandidate,
          callId: 'c-stale',
          candidate: {'candidate': '9.9.9.9'},
        ),
      );
      await a.sendCallSignal(
        _peerB,
        const CallSignal(type: CallSignalType.hangup, callId: 'c-stale'),
      );
      await _pump();
      expect(session.closed, isFalse);
      expect(session.remoteIce, isEmpty);
      expect(session.lastApplied, isNull);

      await a.sendCallSignal(
        _peerB,
        const CallSignal(
          type: CallSignalType.iceCandidate,
          callId: 'c-live',
          candidate: {'candidate': '1.1.1.1'},
        ),
      );
      await _pump();
      expect(session.remoteIce, [
        {'candidate': '1.1.1.1'},
      ]);
      await a.detach();
      await b.detach();
    },
  );

  test(
    'fake and empty SDP never leave DualStack via NativeCallSession',
    () async {
      final (a, b) = await _linked();
      CallSignal? seen;
      b.onCallSignal = (signal, from) => seen = signal;
      final session = NativeCallSession(
        send: (signal) => a.sendCallSignal(_peerB, signal),
      );

      expect(
        await session.startOutgoingIfValid(callId: 'c1', sdp: ''),
        isFalse,
      );
      expect(
        await session.startOutgoingIfValid(callId: 'c1', sdp: 'v=0'),
        isFalse,
      );
      expect(
        await session.startOutgoingIfValid(callId: 'c1', sdp: 'v=0-offer'),
        isFalse,
      );
      await _pump();
      expect(seen, isNull);
      expect((a.transport as LoopbackOrbitsTransport).sentPeerIds, isEmpty);

      expect(
        await session.startOutgoingIfValid(callId: 'c1', sdp: _realSdp),
        isTrue,
      );
      await _pump();
      expect(seen?.type, CallSignalType.offer);
      expect(isSendableCallSdp(seen?.sdp), isTrue);
      await a.detach();
      await b.detach();
    },
  );

  test('DualStack.sendCallSignal itself drops empty or fake SDP', () async {
    final (a, b) = await _linked();
    CallSignal? seen;
    b.onCallSignal = (signal, from) => seen = signal;

    await a.sendCallSignal(
      _peerB,
      const CallSignal(type: CallSignalType.offer, callId: 'c1', sdp: ''),
    );
    await a.sendCallSignal(
      _peerB,
      const CallSignal(type: CallSignalType.offer, callId: 'c1', sdp: 'v=0'),
    );
    await a.sendCallSignal(
      _peerB,
      const CallSignal(
        type: CallSignalType.answer,
        callId: 'c1',
        sdp: 'https://evil.example/sdp',
      ),
    );
    await _pump();
    expect(seen, isNull);

    await a.sendCallSignal(
      _peerB,
      const CallSignal(type: CallSignalType.offer, callId: 'c1', sdp: _realSdp),
    );
    await _pump();
    expect(seen?.sdp, _realSdp);
    await a.detach();
    await b.detach();
  });
}
