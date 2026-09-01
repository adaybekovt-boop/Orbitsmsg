import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/transport/capabilities.dart';
import 'package:orbits_flutter/transport/hello_capabilities.dart';
import 'package:orbits_flutter/transport/signed_capabilities.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  test('capability payload is canonical and sorts wire names', () {
    final record = CapabilityRecord(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-1',
      capabilities: {
        TransportCapability.hyperswarmV1,
        TransportCapability.peerjsV4,
      },
      issuedAt: 1,
      expiresAt: 2,
      signature: Uint8List(0),
      identityPublicKey: Uint8List.fromList(const [1]),
    );
    final text = utf8.decode(record.signedPayload());
    expect(text, startsWith('orbits-capabilities-v1\n'));
    expect(text, contains('hyperswarm-v1,peerjs-v4'));
    expect(record.signedPayload(), record.signedPayload());
  });

  test('identity key signs capabilities; Noise key is not used', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final record = await issueCapabilityRecord(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-1',
      capabilities: {
        TransportCapability.hyperswarmV1,
        TransportCapability.peerjsV4,
      },
      issuedAt: 1,
      expiresAt: 10,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    expect(await verifyCapabilityRecord(record), isTrue);
    expect(record.toWire()['capabilities'], ['hyperswarm-v1', 'peerjs-v4']);
    final again = CapabilityRecord.fromWire(record.toWire());
    expect(await verifyCapabilityRecord(again), isTrue);
    expect(
      logDowngrade(
        selected: TransportRoute.peerjs,
        preferHyperswarm: true,
        localIsPwa: true,
        remoteIsPwa: false,
      )?.reason,
      'pwa',
    );
  });

  test('PeerJS hello caps are verified separately from the hello blob', () async {
    remoteCapabilityCache.clear();
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final record = await issueCapabilityRecord(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-1',
      capabilities: {
        TransportCapability.hyperswarmV1,
        TransportCapability.peerjsV4,
      },
      issuedAt: 1,
      expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    final remembered = await rememberHelloCapabilities(
      'ORBIT-AAAAAAAAAAAAAAAA',
      {
        'type': 'wireHello',
        'v': 3,
        'caps': record.toWire(),
      },
    );
    expect(remembered, isNotNull);
    expect(
      remoteCapabilityCache.get('orbit-aaaaaaaaaaaaaaaa')?.deviceId,
      'dev-1',
    );
    await rememberHelloCapabilities('ORBIT-BBBBBBBBBBBBBBBB', {
      'type': 'wireHello',
      'v': 3,
      'caps': record.toWire(),
    });
    expect(remoteCapabilityCache.get('ORBIT-BBBBBBBBBBBBBBBB'), isNull);
  });
}
