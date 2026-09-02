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

  test(
      'identity-signed lab_directory.json verifies and is not a live fleet',
      () async {
    final fixtureFile = File('tool/fleet/lab_directory.json');
    final raw = Map<String, Object?>.from(
      jsonDecode(await fixtureFile.readAsString()) as Map,
    );
    expect(raw['live'], isFalse);
    expect(raw['signature'], '');
    expect(raw['identityPublicKey'], '');
    expect(kLiveSignedRelayDirectory, isFalse);
    expect(kLiveStorageFleet, isFalse);

    final unsigned = await loadRelayDirectoryFile(fixtureFile.path);
    expect(unsigned, isNotNull);
    expect(relayDirectoryIsUnsignedLab(unsigned!), isTrue);
    expect(await verifyRelayDirectory(unsigned), isFalse);

    // Ephemeral identity-signing-v1 key. Not production. Not Noise.
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final signed = await issueRelayDirectory(
      issuedAt: unsigned.issuedAt,
      expiresAt: unsigned.expiresAt,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
      peers: unsigned.peers,
    );
    expect(await verifyRelayDirectory(signed), isTrue);
    expect(signed.signature, isNotEmpty);
    expect(kLiveSignedRelayDirectory, isFalse);

    final dir = await Directory.systemTemp.createTemp('orbits-lab-signed');
    addTearDown(() => dir.delete(recursive: true));
    final signedFile = File('${dir.path}/lab_directory_signed.json');
    await signedFile.writeAsString(
      jsonEncode(_signedLabDirectoryJson(unsignedBody: raw, signed: signed)),
    );

    final loaded = await loadRelayDirectoryFile(signedFile.path);
    expect(loaded, isNotNull);
    expect(await verifyRelayDirectory(loaded!), isTrue);
    expect(relayDirectoryIsUnsignedLab(loaded), isFalse);
    expect(kLiveSignedRelayDirectory, isFalse);
    expect(kLiveStorageFleet, isFalse);

    final reloadedRaw = jsonDecode(await signedFile.readAsString()) as Map;
    expect(reloadedRaw['live'], isFalse);
    expect(reloadedRaw['signature'], isNotEmpty);
    expect(
      loaded.peers.every((p) => p.host == '127.0.0.1'),
      isTrue,
    );
    expect(
      loaded.pick(DirectoryPeerKind.bootstrap).every(
            (p) => p.wireProtocol == 'http',
          ),
      isTrue,
    );
    expect(bootstrapNodesFromDirectory(loaded), isEmpty);
    expect(relayThroughKeysFromDirectory(loaded), isEmpty);
    expect(isDeniedPublicDhtHost('127.0.0.1'), isFalse);

    expect(loaded.meetsFleetMinimum, isTrue);
    expect(kFleetMinBootstrap, 3);
    expect(kFleetMinRelay, 2);
    expect(kFleetMinStorage, 2);
    expect(loaded.pick(DirectoryPeerKind.bootstrap), hasLength(3));
    expect(loaded.pick(DirectoryPeerKind.relay), hasLength(2));
    expect(loaded.pick(DirectoryPeerKind.storage), hasLength(2));
    expect(
      loaded.pick(DirectoryPeerKind.bootstrap).map((p) => p.id),
      ['bootstrap-1', 'bootstrap-2', 'bootstrap-3'],
    );
    expect(
      loaded.pick(DirectoryPeerKind.relay).map((p) => p.id),
      ['relay-1', 'relay-2'],
    );
    expect(
      loaded.pick(DirectoryPeerKind.storage).map((p) => p.id),
      ['storage-1', 'storage-2'],
    );

    final withUnsound = await issueRelayDirectory(
      issuedAt: unsigned.issuedAt,
      expiresAt: unsigned.expiresAt,
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
      peers: [
        ...unsigned.peers,
        const DirectoryPeer(
          id: 'relay-unsound',
          kind: DirectoryPeerKind.relay,
          host: '127.0.0.1',
          port: 9,
          region: 'lab',
          rttMs: 0,
          unsound: true,
          protocol: 'http',
        ),
      ],
    );
    expect(await verifyRelayDirectory(withUnsound), isTrue);
    expect(
      withUnsound.pick(DirectoryPeerKind.relay).map((p) => p.id),
      ['relay-1', 'relay-2'],
    );
    expect(withUnsound.meetsFleetMinimum, isTrue);
    expect(kLiveSignedRelayDirectory, isFalse);

    final emptySigFile = File('${dir.path}/empty_signature.json');
    await emptySigFile.writeAsString(
      jsonEncode({
        ...raw,
        'signature': '',
        'identityPublicKey': base64Encode(spki),
        'live': false,
      }),
    );
    final emptyLoaded = await loadRelayDirectoryFile(emptySigFile.path);
    expect(emptyLoaded, isNotNull);
    expect(relayDirectoryIsUnsignedLab(emptyLoaded!), isTrue);
    expect(await verifyRelayDirectory(emptyLoaded), isFalse);
    expect(kLiveSignedRelayDirectory, isFalse);

    final tampered = _signedLabDirectoryJson(
      unsignedBody: raw,
      signed: signed,
    );
    ((tampered['peers'] as List).first as Map)['host'] = 'hyperdht.org';
    final tamperedFile = File('${dir.path}/tampered.json');
    await tamperedFile.writeAsString(jsonEncode(tampered));
    expect(await loadRelayDirectoryFile(tamperedFile.path), isNull);
    expect(kLiveSignedRelayDirectory, isFalse);
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
      await loadRelayDirectoryFile('ftp://example.invalid/dir.json'),
      isNull,
    );
    expect(await loadRelayDirectoryFile('file:///tmp/dir.json'), isNull);
    expect(
      await loadRelayDirectoryFile('HTTP://Example.com/dir.json'),
      isNull,
    );
    expect(
      await loadRelayDirectoryFile('lab://embedded/dir.json'),
      isNull,
    );
    expect(kLiveSignedRelayDirectory, isFalse);
    expect(
      await loadRelayDirectoryFromEnv(
        env: {kRelayDirectoryEnv: file.path},
      ),
      isNotNull,
    );
  });

  test('loadRelayDirectoryFile refuses any :// URL; local lab still loads',
      () async {
    expect(await loadRelayDirectoryFile('https://example.com/dir.json'), isNull);
    expect(
      await loadRelayDirectoryFile('ftp://example.invalid/dir.json'),
      isNull,
    );
    expect(await loadRelayDirectoryFile('file:///tmp/dir.json'), isNull);
    expect(
      await loadRelayDirectoryFile('HTTP://Example.com/dir.json'),
      isNull,
    );
    expect(
      await loadRelayDirectoryFile('/tmp/prefix://dir.json'),
      isNull,
    );
    expect(kLiveSignedRelayDirectory, isFalse);

    final lab = await loadRelayDirectoryFile('tool/fleet/lab_directory.json');
    expect(lab, isNotNull);
    expect(relayDirectoryIsUnsignedLab(lab!), isTrue);
    expect(kLiveSignedRelayDirectory, isFalse);
    expect(kLiveStorageFleet, isFalse);
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

/// Overlay a test identity-signing-v1 signature on the committed lab
/// JSON body. Always `live: false`. The public key is ephemeral and
/// not production.
Map<String, Object?> _signedLabDirectoryJson({
  required Map<String, Object?> unsignedBody,
  required RelayDirectory signed,
}) {
  return <String, Object?>{
    ...unsignedBody,
    'signature': base64Encode(signed.signature),
    'identityPublicKey': base64Encode(signed.identityPublicKey),
    'live': false,
    'note':
        'Identity-signed loopback lab directory from tool/fleet/lab_directory.json. '
        'Test identity key only — not production. kLiveSignedRelayDirectory stays false.',
  };
}

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
