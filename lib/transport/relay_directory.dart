// Signed bootstrap / relay / storage directory.
// Clients pick by RTT, skip unsound nodes, and never treat a storage
// peer as a bootstrap.

import 'dart:convert';
import 'dart:typed_data';

import 'signed_capabilities.dart';

enum DirectoryPeerKind { bootstrap, relay, storage }

class DirectoryPeer {
  const DirectoryPeer({
    required this.id,
    required this.kind,
    required this.host,
    required this.port,
    required this.region,
    this.rttMs = 0,
    this.unsound = false,
  });

  final String id;
  final DirectoryPeerKind kind;
  final String host;
  final int port;
  final String region;
  final int rttMs;
  final bool unsound;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'kind': kind.name,
        'host': host,
        'port': port,
        'region': region,
        'rttMs': rttMs,
        'unsound': unsound,
      };

  static DirectoryPeer fromJson(Map<String, Object?> json) {
    final kindName = json['kind'] as String? ?? '';
    return DirectoryPeer(
      id: json['id'] as String? ?? '',
      kind: DirectoryPeerKind.values.firstWhere(
        (k) => k.name == kindName,
        orElse: () => DirectoryPeerKind.relay,
      ),
      host: json['host'] as String? ?? '',
      port: json['port'] is int
          ? json['port'] as int
          : (json['port'] as num?)?.toInt() ?? 0,
      region: json['region'] as String? ?? '',
      rttMs: json['rttMs'] is int
          ? json['rttMs'] as int
          : (json['rttMs'] as num?)?.toInt() ?? 0,
      unsound: json['unsound'] == true,
    );
  }
}

const String kRelayDirectoryInfo = 'orbits-relay-directory-v1';

/// No public signed directory is deployed. Tests sign local fixtures only.
const bool kLiveSignedRelayDirectory = false;

class RelayDirectory {
  const RelayDirectory({
    required this.issuedAt,
    required this.expiresAt,
    required this.peers,
    required this.signature,
    required this.identityPublicKey,
  });

  final int issuedAt;
  final int expiresAt;
  final List<DirectoryPeer> peers;
  final Uint8List signature;
  final Uint8List identityPublicKey;

  List<int> signedPayload() {
    final rows = peers.map((p) => jsonEncode(p.toJson())).toList()..sort();
    return utf8.encode(
      [
        kRelayDirectoryInfo,
        issuedAt.toString(),
        expiresAt.toString(),
        ...rows,
      ].join('\n'),
    );
  }

  List<DirectoryPeer> pick(DirectoryPeerKind kind) {
    final live = peers
        .where((p) => p.kind == kind && !p.unsound && p.host.isNotEmpty)
        .toList()
      ..sort((a, b) => a.rttMs.compareTo(b.rttMs));
    return live;
  }

  bool get meetsFleetMinimum =>
      pick(DirectoryPeerKind.bootstrap).length >= 3 &&
      pick(DirectoryPeerKind.relay).length >= 2 &&
      pick(DirectoryPeerKind.storage).length >= 2;
}

Future<RelayDirectory> issueRelayDirectory({
  required int issuedAt,
  required int expiresAt,
  required List<DirectoryPeer> peers,
  required Uint8List identityPublicKey,
  required Future<Uint8List> Function(List<int> payload) sign,
}) async {
  final draft = RelayDirectory(
    issuedAt: issuedAt,
    expiresAt: expiresAt,
    peers: peers,
    signature: Uint8List(0),
    identityPublicKey: identityPublicKey,
  );
  return RelayDirectory(
    issuedAt: issuedAt,
    expiresAt: expiresAt,
    peers: peers,
    signature: await sign(draft.signedPayload()),
    identityPublicKey: identityPublicKey,
  );
}

Future<bool> verifyRelayDirectory(RelayDirectory directory) async {
  if (directory.expiresAt <= directory.issuedAt) return false;
  return verifyIdentitySignedBytes(
    directory.identityPublicKey,
    directory.signedPayload(),
    directory.signature,
  );
}
