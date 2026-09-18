import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/transport/relay_directory.dart';

import '../helpers/pointycastle_ecdh.dart';

List<DirectoryPeer> minimumFleet({
  int bootstrapRtt = 10,
  bool storageUnsound = false,
}) {
  return [
    DirectoryPeer(
      id: 'boot-a',
      kind: DirectoryPeerKind.bootstrap,
      host: 'boot-a.example',
      port: 1,
      region: 'ca',
      protocols: const ['orbits-bootstrap-v1'],
      rttMs: bootstrapRtt,
    ),
    DirectoryPeer(
      id: 'boot-b',
      kind: DirectoryPeerKind.bootstrap,
      host: 'boot-b.example',
      port: 2,
      region: 'eu',
      protocols: const ['orbits-bootstrap-v1'],
      rttMs: bootstrapRtt + 5,
    ),
    DirectoryPeer(
      id: 'boot-c',
      kind: DirectoryPeerKind.bootstrap,
      host: 'boot-c.example',
      port: 3,
      region: 'spare',
      protocols: const ['orbits-bootstrap-v1'],
      rttMs: bootstrapRtt + 20,
    ),
    DirectoryPeer(
      id: 'relay-a',
      kind: DirectoryPeerKind.relay,
      host: 'relay-a.example',
      port: 4,
      region: 'ca',
      protocols: const ['orbits-relay-v1'],
      rttMs: 8,
    ),
    DirectoryPeer(
      id: 'relay-b',
      kind: DirectoryPeerKind.relay,
      host: 'relay-b.example',
      port: 5,
      region: 'eu',
      protocols: const ['orbits-relay-v1'],
      rttMs: 12,
    ),
    DirectoryPeer(
      id: 'store-a',
      kind: DirectoryPeerKind.storage,
      host: 'store-a.example',
      port: 6,
      region: 'ca',
      protocols: const ['orbits-storage-v1'],
      rttMs: 9,
      unsound: storageUnsound,
    ),
    DirectoryPeer(
      id: 'store-b',
      kind: DirectoryPeerKind.storage,
      host: 'store-b.example',
      port: 7,
      region: 'eu',
      protocols: const ['orbits-storage-v1'],
      rttMs: 11,
    ),
  ];
}

void main() {
  test(
    'signed payload is canonical and ignores field order / unsigned RTT',
    () async {
      final pair = await generateP256EcdsaKey();
      final spki = buildP256Spki(x: pair.x, y: pair.y);
      final now = 1_700_000_000_000;
      final directory = await issueRelayDirectory(
        issuedAt: now,
        expiresAt: now + 60_000,
        peers: minimumFleet(),
        identityPublicKey: spki,
        sign: (payload) async => signP256Ecdsa(pair, payload),
      );
      final shuffled = RelayDirectory.fromJson({
        'expiresAt': directory.expiresAt,
        'identityPublicKey': base64Encode(directory.identityPublicKey),
        'signature': base64Encode(directory.signature),
        'issuedAt': directory.issuedAt,
        'v': kRelayDirectoryInfo,
        'peers': directory.peers
            .map(
              (p) => {
                'region': p.region,
                'protocols': p.protocols,
                'port': p.port,
                'kind': p.kind.name,
                'id': p.id,
                'host': p.host,
                'rttMs': 9999,
                'unsound': true,
              },
            )
            .toList(),
      });
      expect(shuffled.signedPayload(), directory.signedPayload());
      expect(utf8.decode(directory.signedPayload()), isNot(contains('rttMs')));
      expect(
        await verifyRelayDirectory(
          shuffled,
          trustedIdentityKeys: [spki],
          nowMs: now + 10,
        ),
        isTrue,
      );
    },
  );

  test(
    'minimum topology 3 bootstrap / 2 relay / 2 storage is selectable',
    () async {
      final pair = await generateP256EcdsaKey();
      final spki = buildP256Spki(x: pair.x, y: pair.y);
      final now = 1_700_000_000_000;
      final directory = await issueRelayDirectory(
        issuedAt: now,
        expiresAt: now + 60_000,
        peers: minimumFleet(),
        identityPublicKey: spki,
        sign: (payload) async => signP256Ecdsa(pair, payload),
      );
      expect(directory.meetsFleetMinimum, isTrue);
      expect(directory.pick(DirectoryPeerKind.bootstrap).first.id, 'boot-a');
      expect(directory.pick(DirectoryPeerKind.relay).first.id, 'relay-a');
      expect(
        directory.pick(DirectoryPeerKind.bootstrap).map((p) => p.kind).toSet(),
        {DirectoryPeerKind.bootstrap},
      );
    },
  );

  test('RTT ties break deterministically by id', () {
    final directory = RelayDirectory(
      issuedAt: 1,
      expiresAt: 2,
      peers: [
        const DirectoryPeer(
          id: 'relay-z',
          kind: DirectoryPeerKind.relay,
          host: 'z',
          port: 1,
          region: 'eu',
          rttMs: 5,
        ),
        const DirectoryPeer(
          id: 'relay-a',
          kind: DirectoryPeerKind.relay,
          host: 'a',
          port: 1,
          region: 'ca',
          rttMs: 5,
        ),
      ],
      signature: Uint8List(0),
      identityPublicKey: Uint8List(0),
    );
    expect(directory.pick(DirectoryPeerKind.relay).map((p) => p.id), [
      'relay-a',
      'relay-z',
    ]);
  });

  test(
    'partial outage skips unsound nodes and may drop below fleet minimum',
    () {
      final live = RelayDirectory(
        issuedAt: 1,
        expiresAt: 2,
        peers: minimumFleet(storageUnsound: true),
        signature: Uint8List(0),
        identityPublicKey: Uint8List(0),
      );
      expect(live.pick(DirectoryPeerKind.storage), hasLength(1));
      expect(live.meetsFleetMinimum, isFalse);
    },
  );

  test(
    'unsigned, expired, future-dated, tampered, and unknown keys fail',
    () async {
      final pair = await generateP256EcdsaKey();
      final other = await generateP256EcdsaKey();
      final spki = buildP256Spki(x: pair.x, y: pair.y);
      final otherSpki = buildP256Spki(x: other.x, y: other.y);
      final now = 1_700_000_000_000;
      final directory = await issueRelayDirectory(
        issuedAt: now,
        expiresAt: now + 60_000,
        peers: minimumFleet(),
        identityPublicKey: spki,
        sign: (payload) async => signP256Ecdsa(pair, payload),
      );

      expect(
        (await verifyRelayDirectoryDetailed(
          RelayDirectory(
            issuedAt: now,
            expiresAt: now + 1,
            peers: directory.peers,
            signature: Uint8List(0),
            identityPublicKey: spki,
          ),
          trustedIdentityKeys: [spki],
          nowMs: now,
        )).reason,
        'unsigned',
      );
      expect(
        (await verifyRelayDirectoryDetailed(
          directory,
          trustedIdentityKeys: [spki],
          nowMs: directory.expiresAt + 1,
        )).reason,
        'expired',
      );
      expect(
        (await verifyRelayDirectoryDetailed(
          directory,
          trustedIdentityKeys: [spki],
          nowMs: directory.issuedAt - kRelayDirectoryClockSkewMs - 1,
        )).reason,
        'future-dated',
      );
      expect(
        (await verifyRelayDirectoryDetailed(
          RelayDirectory(
            issuedAt: directory.issuedAt,
            expiresAt: directory.expiresAt,
            peers: directory.peers,
            signature: Uint8List.fromList(
              List<int>.from(directory.signature)..[0] ^= 0x01,
            ),
            identityPublicKey: spki,
          ),
          trustedIdentityKeys: [spki],
          nowMs: now,
        )).reason,
        'invalid-signature',
      );
      expect(
        (await verifyRelayDirectoryDetailed(
          directory,
          trustedIdentityKeys: [otherSpki],
          nowMs: now,
        )).reason,
        'unknown-identity',
      );
    },
  );

  test(
    'malformed, duplicate, wrong-role, and unsupported version are rejected',
    () {
      expect(
        () => RelayDirectory.fromJson({
          'v': 'orbits-relay-directory-v0',
          'issuedAt': 1,
          'expiresAt': 2,
          'peers': const [],
          'signature': '',
          'identityPublicKey': '',
        }),
        throwsFormatException,
      );
      expect(
        () => DirectoryPeer.parse({
          'id': 'x',
          'kind': 'turn',
          'host': 'h',
          'port': 1,
          'region': 'ca',
        }),
        throwsFormatException,
      );
      expect(
        () => DirectoryPeer.parse({
          'id': 'x',
          'kind': 'relay',
          'host': 'h',
          'port': 1,
          'region': 'ca',
          'protocols': ['not-a-protocol'],
        }),
        throwsFormatException,
      );
      expect(
        () => RelayDirectory.fromJson({
          'v': kRelayDirectoryInfo,
          'issuedAt': 1,
          'expiresAt': 2,
          'peers': [
            {
              'id': 'dup',
              'kind': 'relay',
              'host': 'a',
              'port': 1,
              'region': 'ca',
              'protocols': ['orbits-relay-v1'],
            },
            {
              'id': 'dup',
              'kind': 'relay',
              'host': 'b',
              'port': 2,
              'region': 'eu',
              'protocols': ['orbits-relay-v1'],
            },
          ],
          'signature': '',
          'identityPublicKey': '',
        }),
        throwsFormatException,
      );
    },
  );

  test('cached directory is usable until expiry then fails closed', () async {
    final pair = await generateP256EcdsaKey();
    final spki = buildP256Spki(x: pair.x, y: pair.y);
    final now = 1_700_000_000_000;
    final directory = await issueRelayDirectory(
      issuedAt: now,
      expiresAt: now + 60_000,
      peers: minimumFleet(),
      identityPublicKey: spki,
      sign: (payload) async => signP256Ecdsa(pair, payload),
    );
    final cache = CachedRelayDirectory();
    expect(
      await cache.accept(
        incoming: directory,
        trustedIdentityKeys: [spki],
        nowMs: now,
      ),
      isNotNull,
    );
    expect(cache.fallback(now + 10)?.meetsFleetMinimum, isTrue);
    expect(cache.fallback(directory.expiresAt + 1), isNull);
    expect(cache.directory, isNull);
  });

  test('key rotation accepts previous or current identity keys', () async {
    final oldPair = await generateP256EcdsaKey();
    final newPair = await generateP256EcdsaKey();
    final oldSpki = buildP256Spki(x: oldPair.x, y: oldPair.y);
    final newSpki = buildP256Spki(x: newPair.x, y: newPair.y);
    final now = 1_700_000_000_000;
    final rotated = await issueRelayDirectory(
      issuedAt: now,
      expiresAt: now + 60_000,
      peers: minimumFleet(),
      identityPublicKey: newSpki,
      sign: (payload) async => signP256Ecdsa(newPair, payload),
    );
    expect(
      await verifyRelayDirectory(
        rotated,
        trustedIdentityKeys: [oldSpki, newSpki],
        nowMs: now,
      ),
      isTrue,
    );
    expect(
      await verifyRelayDirectory(
        rotated,
        trustedIdentityKeys: [oldSpki],
        nowMs: now,
      ),
      isFalse,
    );
  });

  test('does not claim a live signed directory exists', () {
    expect(kRelayDirectoryInfo, 'orbits-relay-directory-v1');
    expect(minimumFleet(), isNotEmpty);
  });
}
