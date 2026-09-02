import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/transport/dht_bootstrap.dart';
import 'package:orbits_flutter/transport/fleet_status.dart';
import 'package:orbits_flutter/transport/relay_directory.dart';
import 'package:orbits_flutter/transport/relay_directory_load.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  test('no live signed directory is claimed', () {
    expect(kLiveSignedRelayDirectory, isFalse);
    expect(kLiveStorageFleet, isFalse);
  });

  test('identity-signed directory verifies; Noise is not used', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    const now = 1;
    final directory = await issueRelayDirectory(
      issuedAt: now,
      expiresAt: now + 60,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
      peers: _fleetPeers(),
    );
    expect(await verifyRelayDirectory(directory), isTrue);
    expect(directory.signedPayload(), directory.signedPayload());
    expect(
      utf8Payload(directory),
      startsWith('$kRelayDirectoryInfo\n'),
    );
  });

  test('pick skips unsound nodes and sorts by RTT', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final directory = await issueRelayDirectory(
      issuedAt: 1,
      expiresAt: 10,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
      peers: [
        const DirectoryPeer(
          id: 'r-slow',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.1',
          port: 1,
          region: 'eu',
          rttMs: 80,
        ),
        const DirectoryPeer(
          id: 'r-fast',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.2',
          port: 1,
          region: 'eu',
          rttMs: 12,
        ),
        const DirectoryPeer(
          id: 'r-bad',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.3',
          port: 1,
          region: 'eu',
          rttMs: 1,
          unsound: true,
        ),
        const DirectoryPeer(
          id: 's-as-relay',
          kind: DirectoryPeerKind.storage,
          host: '10.0.0.9',
          port: 1,
          region: 'eu',
          rttMs: 2,
        ),
      ],
    );
    final relays = directory.pick(DirectoryPeerKind.relay);
    expect(relays.map((p) => p.id), ['r-fast', 'r-slow']);
    expect(
      directory.pick(DirectoryPeerKind.storage).single.id,
      's-as-relay',
    );
  });

  test('fleet minimum is 3 bootstrap / 2 relay / 2 storage', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final full = await issueRelayDirectory(
      issuedAt: 1,
      expiresAt: 10,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
      peers: _fleetPeers(),
    );
    expect(full.meetsFleetMinimum, isTrue);
    expect(kFleetMinBootstrap, 3);
    expect(kFleetMinRelay, 2);
    expect(kFleetMinStorage, 2);

    final short = await issueRelayDirectory(
      issuedAt: 1,
      expiresAt: 10,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
      peers: [
        ..._fleetPeers().where((p) => p.kind != DirectoryPeerKind.bootstrap),
        const DirectoryPeer(
          id: 'b1',
          kind: DirectoryPeerKind.bootstrap,
          host: '1.1.1.1',
          port: 1,
          region: 'ca',
        ),
        const DirectoryPeer(
          id: 'b2',
          kind: DirectoryPeerKind.bootstrap,
          host: '1.1.1.2',
          port: 1,
          region: 'eu',
        ),
        const DirectoryPeer(
          id: 'b-unsound',
          kind: DirectoryPeerKind.bootstrap,
          host: '1.1.1.3',
          port: 1,
          region: 'spare',
          unsound: true,
        ),
      ],
    );
    expect(short.pick(DirectoryPeerKind.bootstrap), hasLength(2));
    expect(short.meetsFleetMinimum, isFalse);
  });

  test('tampered directory fails identity verify', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final good = await issueRelayDirectory(
      issuedAt: 1,
      expiresAt: 10,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
      peers: _fleetPeers(),
    );
    final tampered = RelayDirectory(
      issuedAt: good.issuedAt,
      expiresAt: good.expiresAt,
      identityPublicKey: good.identityPublicKey,
      signature: good.signature,
      peers: [
        ...good.peers.skip(1),
        DirectoryPeer(
          id: good.peers.first.id,
          kind: good.peers.first.kind,
          host: 'evil.example',
          port: good.peers.first.port,
          region: good.peers.first.region,
        ),
      ],
    );
    expect(await verifyRelayDirectory(tampered), isFalse);
    expect(
      await verifyRelayDirectory(
        RelayDirectory(
          issuedAt: 10,
          expiresAt: 10,
          identityPublicKey: good.identityPublicKey,
          signature: good.signature,
          peers: good.peers,
        ),
      ),
      isFalse,
    );
  });

  test('committed lab_directory.json is unsigned and is not a DHT fleet',
      () async {
    final loaded =
        await loadRelayDirectoryFile('tool/fleet/lab_directory.json');
    expect(loaded, isNotNull);
    final directory = loaded!;
    expect(kLiveSignedRelayDirectory, isFalse);
    expect(kLiveStorageFleet, isFalse);
    expect(relayDirectoryIsUnsignedLab(directory), isTrue);
    expect(directory.meetsFleetMinimum, isTrue);
    expect(directory.signature, isEmpty);
    expect(directory.identityPublicKey, isEmpty);
    expect(await verifyRelayDirectory(directory), isFalse);
    expect(bootstrapNodesFromDirectory(directory), isEmpty);
    expect(relayThroughKeysFromDirectory(directory), isEmpty);
    expect(
      directory.pick(DirectoryPeerKind.bootstrap).every(
            (p) => p.wireProtocol == 'http',
          ),
      isTrue,
    );
  });

  test('unsigned lab directory file loads; URLs are refused', () async {
    final dir = await Directory.systemTemp.createTemp('orbits-relay-dir');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/directory.json');
    await file.writeAsString(
      jsonEncode({
        'issuedAt': 1,
        'expiresAt': 10,
        'peers': _fleetPeers().map((p) => p.toJson()).toList(),
      }),
    );
    final loaded = await loadRelayDirectoryFile(file.path);
    expect(loaded, isNotNull);
    expect(loaded!.meetsFleetMinimum, isTrue);
    expect(kLiveSignedRelayDirectory, isFalse);
    expect(await loadRelayDirectoryFile('https://example.com/dir.json'), isNull);
    expect(await loadRelayDirectoryFile('http://127.0.0.1/dir.json'), isNull);
    expect(
      await loadRelayDirectoryFromEnv(
        env: {kRelayDirectoryEnv: file.path},
      ),
      isNotNull,
    );
  });

  test('signed directory file verifies; tamper is dropped', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final good = await issueRelayDirectory(
      issuedAt: 1,
      expiresAt: 10,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
      peers: _fleetPeers(),
    );
    final dir = await Directory.systemTemp.createTemp('orbits-relay-signed');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/signed.json');
    await file.writeAsString(jsonEncode(relayDirectoryToJson(good)));
    final loaded = await loadRelayDirectoryFile(file.path);
    expect(loaded, isNotNull);
    expect(await verifyRelayDirectory(loaded!), isTrue);

    final tampered = relayDirectoryToJson(good);
    (tampered['peers'] as List).first['host'] = 'evil.example';
    await file.writeAsString(jsonEncode(tampered));
    expect(await loadRelayDirectoryFile(file.path), isNull);
  });

  test('relayBlownUp is false without relays and true when the set collapses',
      () {
    final empty = RelayDirectory(
      issuedAt: 1,
      expiresAt: 2,
      peers: const [],
      signature: Uint8List(0),
      identityPublicKey: Uint8List(0),
    );
    expect(empty.relayBlownUp, isFalse);

    final healthy = RelayDirectory(
      issuedAt: 1,
      expiresAt: 2,
      peers: const [
        DirectoryPeer(
          id: 'r1',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.1',
          port: 1,
          region: 'eu',
          rttMs: 12,
        ),
        DirectoryPeer(
          id: 'r2',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.2',
          port: 1,
          region: 'eu',
          rttMs: 20,
        ),
      ],
      signature: Uint8List(0),
      identityPublicKey: Uint8List(0),
    );
    expect(healthy.relayBlownUp, isFalse);

    final unsound = RelayDirectory(
      issuedAt: 1,
      expiresAt: 2,
      peers: const [
        DirectoryPeer(
          id: 'r1',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.1',
          port: 1,
          region: 'eu',
          unsound: true,
        ),
        DirectoryPeer(
          id: 'r2',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.2',
          port: 1,
          region: 'eu',
          unsound: true,
        ),
      ],
      signature: Uint8List(0),
      identityPublicKey: Uint8List(0),
    );
    expect(unsound.relayBlownUp, isTrue);

    final belowMin = RelayDirectory(
      issuedAt: 1,
      expiresAt: 2,
      peers: const [
        DirectoryPeer(
          id: 'r1',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.1',
          port: 1,
          region: 'eu',
          rttMs: 8,
        ),
        DirectoryPeer(
          id: 'r2',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.2',
          port: 1,
          region: 'eu',
          unsound: true,
        ),
      ],
      signature: Uint8List(0),
      identityPublicKey: Uint8List(0),
    );
    expect(belowMin.relayBlownUp, isTrue);

    final slow = RelayDirectory(
      issuedAt: 1,
      expiresAt: 2,
      peers: const [
        DirectoryPeer(
          id: 'r1',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.1',
          port: 1,
          region: 'eu',
          rttMs: kRelayBlowUpRttMs,
        ),
        DirectoryPeer(
          id: 'r2',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.2',
          port: 1,
          region: 'eu',
          rttMs: kRelayBlowUpRttMs + 1,
        ),
      ],
      signature: Uint8List(0),
      identityPublicKey: Uint8List(0),
    );
    expect(slow.relayBlownUp, isTrue);
  });

  test('epoch-millis lab directories expire; dummy timestamps do not', () async {
    final dir = await Directory.systemTemp.createTemp('orbits-relay-exp');
    addTearDown(() => dir.delete(recursive: true));
    final expired = File('${dir.path}/expired.json');
    await expired.writeAsString(
      jsonEncode({
        'issuedAt': 1000000000000,
        'expiresAt': 1000000001000,
        'peers': _fleetPeers().map((p) => p.toJson()).toList(),
      }),
    );
    expect(
      await loadRelayDirectoryFile(expired.path, nowMs: 1000000002000),
      isNull,
    );
    final live = File('${dir.path}/live.json');
    await live.writeAsString(
      jsonEncode({
        'issuedAt': 1000000000000,
        'expiresAt': 2000000000000,
        'peers': _fleetPeers().map((p) => p.toJson()).toList(),
      }),
    );
    expect(
      await loadRelayDirectoryFile(live.path, nowMs: 1500000000000),
      isNotNull,
    );
    expect(kLiveSignedRelayDirectory, isFalse);
  });
}

String utf8Payload(RelayDirectory directory) =>
    String.fromCharCodes(directory.signedPayload());

List<DirectoryPeer> _fleetPeers() => const [
      DirectoryPeer(
        id: 'b-ca',
        kind: DirectoryPeerKind.bootstrap,
        host: '10.1.0.1',
        port: 49737,
        region: 'central-asia',
        rttMs: 40,
      ),
      DirectoryPeer(
        id: 'b-eu',
        kind: DirectoryPeerKind.bootstrap,
        host: '10.1.0.2',
        port: 49737,
        region: 'europe',
        rttMs: 20,
      ),
      DirectoryPeer(
        id: 'b-spare',
        kind: DirectoryPeerKind.bootstrap,
        host: '10.1.0.3',
        port: 49737,
        region: 'spare',
        rttMs: 90,
      ),
      DirectoryPeer(
        id: 'r1',
        kind: DirectoryPeerKind.relay,
        host: '10.2.0.1',
        port: 49737,
        region: 'europe',
        rttMs: 18,
      ),
      DirectoryPeer(
        id: 'r2',
        kind: DirectoryPeerKind.relay,
        host: '10.2.0.2',
        port: 49737,
        region: 'central-asia',
        rttMs: 35,
      ),
      DirectoryPeer(
        id: 's1',
        kind: DirectoryPeerKind.storage,
        host: '10.3.0.1',
        port: 8787,
        region: 'europe',
        rttMs: 22,
      ),
      DirectoryPeer(
        id: 's2',
        kind: DirectoryPeerKind.storage,
        host: '10.3.0.2',
        port: 8787,
        region: 'central-asia',
        rttMs: 41,
      ),
    ];
