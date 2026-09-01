import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/transport/fleet_status.dart';
import 'package:orbits_flutter/transport/relay_directory.dart';

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
