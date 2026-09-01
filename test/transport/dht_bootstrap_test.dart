import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/dht_bootstrap.dart';
import 'package:orbits_flutter/transport/relay_directory.dart';
import 'package:orbits_flutter/transport/transport_api.dart';

void main() {
  test('empty env is not the public DHT', () {
    expect(parseDhtBootstrapEnv(null), isEmpty);
    expect(parseDhtBootstrapEnv(''), isEmpty);
    expect(parseDhtBootstrapEnv('   '), isEmpty);
    expect(resolveDhtBootstrap(env: const {}), isEmpty);
  });

  test('parses host:port lists and skips public introducers', () {
    expect(
      parseDhtBootstrapEnv('127.0.0.1:49737,10.0.0.2:1234'),
      [
        const DhtBootstrapNode(host: '127.0.0.1', port: 49737),
        const DhtBootstrapNode(host: '10.0.0.2', port: 1234),
      ],
    );
    expect(
      parseDhtBootstrapEnv('[::1]:49737'),
      [const DhtBootstrapNode(host: '::1', port: 49737)],
    );
    expect(parseDhtBootstrapEnv('bootstrap1.hyperdht.org:49737'), isEmpty);
    expect(parseDhtBootstrapEnv('s1.hypercore.io:49737'), isEmpty);
    expect(isDeniedPublicDhtHost('holepunch.to'), isTrue);
  });

  test('directory bootstrap wins over env and skips unsound/public', () {
    final directory = RelayDirectory(
      issuedAt: 1,
      expiresAt: 10,
      signature: Uint8List(0),
      identityPublicKey: Uint8List(0),
      peers: const [
        DirectoryPeer(
          id: 'b-slow',
          kind: DirectoryPeerKind.bootstrap,
          host: '10.1.0.2',
          port: 49737,
          region: 'eu',
          rttMs: 80,
        ),
        DirectoryPeer(
          id: 'b-fast',
          kind: DirectoryPeerKind.bootstrap,
          host: '10.1.0.1',
          port: 49737,
          region: 'ca',
          rttMs: 12,
        ),
        DirectoryPeer(
          id: 'b-public',
          kind: DirectoryPeerKind.bootstrap,
          host: 'bootstrap1.hyperdht.org',
          port: 49737,
          region: 'x',
        ),
        DirectoryPeer(
          id: 's1',
          kind: DirectoryPeerKind.storage,
          host: '10.3.0.1',
          port: 8787,
          region: 'eu',
          rttMs: 5,
        ),
      ],
    );
    expect(
      resolveDhtBootstrap(
        env: const {kDhtBootstrapEnv: '127.0.0.1:1'},
        directory: directory,
      ),
      [
        const DhtBootstrapNode(host: '10.1.0.1', port: 49737),
        const DhtBootstrapNode(host: '10.1.0.2', port: 49737),
      ],
    );
    expect(
      resolveStoragePeerOrigin(directory: directory),
      'http://10.3.0.1:8787',
    );
    expect(
      resolveStoragePeerOrigin(
        env: const {kStoragePeerOriginEnv: 'http://127.0.0.1:9'},
        directory: directory,
      ),
      'http://127.0.0.1:9',
    );
  });

  test('storage rows are never used as bootstrap', () {
    final directory = RelayDirectory(
      issuedAt: 1,
      expiresAt: 10,
      signature: Uint8List(0),
      identityPublicKey: Uint8List(0),
      peers: const [
        DirectoryPeer(
          id: 's1',
          kind: DirectoryPeerKind.storage,
          host: '10.3.0.1',
          port: 8787,
          region: 'eu',
        ),
      ],
    );
    expect(bootstrapNodesFromDirectory(directory), isEmpty);
    expect(storageOriginFromPeer(directory.peers.single), 'http://10.3.0.1:8787');
  });

  test('HTTP lab bootstrap rows are not HyperDHT addresses', () {
    final directory = RelayDirectory(
      issuedAt: 1,
      expiresAt: 10,
      signature: Uint8List(0),
      identityPublicKey: Uint8List(0),
      peers: const [
        DirectoryPeer(
          id: 'b-http',
          kind: DirectoryPeerKind.bootstrap,
          host: '127.0.0.1',
          port: 9,
          region: 'lab',
          protocol: 'http',
        ),
        DirectoryPeer(
          id: 'b-dht',
          kind: DirectoryPeerKind.bootstrap,
          host: '127.0.0.1',
          port: 49737,
          region: 'lab',
          protocol: 'hyperdht',
        ),
      ],
    );
    expect(
      bootstrapNodesFromDirectory(directory),
      [const DhtBootstrapNode(host: '127.0.0.1', port: 49737)],
    );
  });
}
