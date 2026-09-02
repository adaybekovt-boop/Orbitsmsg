import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/transport/capabilities.dart';
import 'package:orbits_flutter/transport/hello_capabilities.dart';
import 'package:orbits_flutter/transport/signed_capabilities.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  setUp(() {
    resetFlagsForTests();
    remoteCapabilityCache.clear();
  });
  tearDown(() {
    resetFlagsForTests();
    remoteCapabilityCache.clear();
  });

  const native = {
    TransportCapability.hyperswarmV1,
    TransportCapability.peerjsV4,
  };
  const oldNative = {TransportCapability.peerjsV4};
  const pwa = {TransportCapability.peerjsV4, TransportCapability.webPwaV1};

  final rows =
      <
        ({
          String name,
          Set<TransportCapability> local,
          Set<TransportCapability> remote,
          bool localPwa,
          bool remotePwa,
          bool prefer,
          bool fallback,
          TransportRoute expected,
        })
      >[
        (
          name: 'new-native / new-native',
          local: native,
          remote: native,
          localPwa: false,
          remotePwa: false,
          prefer: true,
          fallback: true,
          expected: TransportRoute.hyperswarm,
        ),
        (
          name: 'new-native / old-native',
          local: native,
          remote: oldNative,
          localPwa: false,
          remotePwa: false,
          prefer: true,
          fallback: true,
          expected: TransportRoute.peerjs,
        ),
        (
          name: 'old-native / new-native',
          local: oldNative,
          remote: native,
          localPwa: false,
          remotePwa: false,
          prefer: true,
          fallback: true,
          expected: TransportRoute.peerjs,
        ),
        (
          name: 'old-native / old-native',
          local: oldNative,
          remote: oldNative,
          localPwa: false,
          remotePwa: false,
          prefer: true,
          fallback: true,
          expected: TransportRoute.peerjs,
        ),
        (
          name: 'new-native / pwa',
          local: native,
          remote: pwa,
          localPwa: false,
          remotePwa: true,
          prefer: true,
          fallback: true,
          expected: TransportRoute.peerjs,
        ),
        (
          name: 'pwa / new-native',
          local: pwa,
          remote: native,
          localPwa: true,
          remotePwa: false,
          prefer: true,
          fallback: true,
          expected: TransportRoute.peerjs,
        ),
        (
          name: 'pwa / pwa',
          local: pwa,
          remote: pwa,
          localPwa: true,
          remotePwa: true,
          prefer: true,
          fallback: true,
          expected: TransportRoute.peerjs,
        ),
        (
          name: 'old-native / pwa',
          local: oldNative,
          remote: pwa,
          localPwa: false,
          remotePwa: true,
          prefer: true,
          fallback: true,
          expected: TransportRoute.peerjs,
        ),
        (
          name: 'pwa / old-native',
          local: pwa,
          remote: oldNative,
          localPwa: true,
          remotePwa: false,
          prefer: true,
          fallback: true,
          expected: TransportRoute.peerjs,
        ),
        (
          name: 'new-native / old-native no fallback',
          local: native,
          remote: oldNative,
          localPwa: false,
          remotePwa: false,
          prefer: true,
          fallback: false,
          expected: TransportRoute.unavailable,
        ),
        (
          name: 'pwa / pwa no fallback',
          local: pwa,
          remote: pwa,
          localPwa: true,
          remotePwa: true,
          prefer: true,
          fallback: false,
          expected: TransportRoute.unavailable,
        ),
      ];

  for (final row in rows) {
    test('route matrix: ${row.name}', () {
      expect(
        selectTransportRoute(
          local: row.local,
          remote: row.remote,
          preferHyperswarm: row.prefer,
          allowPeerjsFallback: row.fallback,
          localIsPwa: row.localPwa,
          remoteIsPwa: row.remotePwa,
        ),
        row.expected,
      );
    });
  }

  test('per-contact fallback prohibition fails closed', () {
    remoteCapabilityCache.forbidFallback('ORBIT-AAAAAAAAAAAAAAAA');
    expect(
      remoteCapabilityCache.fallbackForbidden('ORBIT-AAAAAAAAAAAAAAAA'),
      isTrue,
    );
    expect(
      selectTransportRoute(
        local: native,
        remote: oldNative,
        allowPeerjsFallback: !remoteCapabilityCache.fallbackForbidden(
          'ORBIT-AAAAAAAAAAAAAAAA',
        ),
      ),
      TransportRoute.unavailable,
    );
  });

  test('stripped and replayed capabilities are rejected', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final record = await issueCapabilityRecord(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-1',
      capabilities: native,
      issuedAt: 1,
      expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    final hello = {'type': 'wireHello', 'v': 3, 'caps': record.toWire()};
    expect(
      await rememberHelloCapabilities('ORBIT-AAAAAAAAAAAAAAAA', hello),
      isNotNull,
    );
    expect(
      await rememberHelloCapabilities('ORBIT-AAAAAAAAAAAAAAAA', hello),
      isNull,
    );
    expect(
      capabilityWasStripped('ORBIT-AAAAAAAAAAAAAAAA', {'type': 'wireHello'}),
      isTrue,
    );
    remoteCapabilityCache.revoke('ORBIT-AAAAAAAAAAAAAAAA');
    expect(remoteCapabilityCache.get('ORBIT-AAAAAAAAAAAAAAAA'), isNull);
    expect(
      await rememberHelloCapabilities('ORBIT-AAAAAAAAAAAAAAAA', {
        'type': 'wireHello',
        'caps': record.toWire(),
      }),
      isNull,
    );
  });

  test('expired capability is not cached', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final record = await issueCapabilityRecord(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-1',
      capabilities: native,
      issuedAt: 1,
      expiresAt: 2,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    expect(
      await rememberHelloCapabilities('ORBIT-AAAAAAAAAAAAAAAA', {
        'type': 'wireHello',
        'caps': record.toWire(),
      }),
      isNull,
    );
  });
}
