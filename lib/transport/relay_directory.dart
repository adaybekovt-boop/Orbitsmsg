// Signed bootstrap / relay / storage directory.
// Clients pick by locally measured RTT, skip unsound nodes, and never
// treat a storage peer as a bootstrap. Unsigned RTT/health are never
// authorization. This is not a live public fleet.

import 'dart:convert';
import 'dart:typed_data';

import 'signed_capabilities.dart';

const String kRelayDirectoryInfo = 'orbits-relay-directory-v1';
const int kRelayDirectoryClockSkewMs = 5 * 60 * 1000;
const Set<String> kSupportedRelayProtocols = {
  'orbits-bootstrap-v1',
  'orbits-relay-v1',
  'orbits-storage-v1',
};

enum DirectoryPeerKind { bootstrap, relay, storage }

class DirectoryPeer {
  const DirectoryPeer({
    required this.id,
    required this.kind,
    required this.host,
    required this.port,
    required this.region,
    this.protocols = const <String>[],
    this.rttMs = 0,
    this.unsound = false,
    this.healthy = true,
  });

  final String id;
  final DirectoryPeerKind kind;
  final String host;
  final int port;
  final String region;
  final List<String> protocols;

  /// Local measurement. Never part of the signed payload.
  final int rttMs;

  /// Local / operator overlay. Never part of the signed payload.
  final bool unsound;
  final bool healthy;

  String get requiredProtocol => switch (kind) {
    DirectoryPeerKind.bootstrap => 'orbits-bootstrap-v1',
    DirectoryPeerKind.relay => 'orbits-relay-v1',
    DirectoryPeerKind.storage => 'orbits-storage-v1',
  };

  Map<String, Object?> toCanonicalJson() {
    final proto = [...protocols]..sort();
    return <String, Object?>{
      'host': host,
      'id': id,
      'kind': kind.name,
      'port': port,
      'protocols': proto,
      'region': region,
    };
  }

  Map<String, Object?> toJson() => <String, Object?>{
    ...toCanonicalJson(),
    'rttMs': rttMs,
    'unsound': unsound,
    'healthy': healthy,
  };

  DirectoryPeer withLocalMeasurement({
    int? rttMs,
    bool? unsound,
    bool? healthy,
  }) {
    return DirectoryPeer(
      id: id,
      kind: kind,
      host: host,
      port: port,
      region: region,
      protocols: protocols,
      rttMs: rttMs ?? this.rttMs,
      unsound: unsound ?? this.unsound,
      healthy: healthy ?? this.healthy,
    );
  }

  static DirectoryPeer parse(Map<String, Object?> json) {
    final kindName = json['kind'] as String? ?? '';
    DirectoryPeerKind? kind;
    for (final value in DirectoryPeerKind.values) {
      if (value.name == kindName) kind = value;
    }
    if (kind == null) {
      throw const FormatException('unsupported directory peer role');
    }
    final id = json['id'] as String? ?? '';
    final host = json['host'] as String? ?? '';
    final port = json['port'] is int
        ? json['port'] as int
        : int.tryParse('${json['port']}') ?? 0;
    if (id.isEmpty || host.isEmpty || port <= 0 || port > 65535) {
      throw const FormatException('malformed directory peer');
    }
    final protocols = (json['protocols'] as List? ?? const [])
        .whereType<String>()
        .toList(growable: false);
    for (final protocol in protocols) {
      if (!kSupportedRelayProtocols.contains(protocol)) {
        throw FormatException('unsupported directory protocol');
      }
    }
    return DirectoryPeer(
      id: id,
      kind: kind,
      host: host,
      port: port,
      region: json['region'] as String? ?? '',
      protocols: protocols,
      rttMs: json['rttMs'] is int ? json['rttMs'] as int : 0,
      unsound: json['unsound'] == true,
      healthy: json['healthy'] != false,
    );
  }

  static DirectoryPeer fromJson(Map<String, Object?> json) => parse(json);
}

class RelayDirectory {
  const RelayDirectory({
    required this.issuedAt,
    required this.expiresAt,
    required this.peers,
    required this.signature,
    required this.identityPublicKey,
    this.version = kRelayDirectoryInfo,
  });

  final String version;
  final int issuedAt;
  final int expiresAt;
  final List<DirectoryPeer> peers;
  final Uint8List signature;
  final Uint8List identityPublicKey;

  List<int> signedPayload() {
    final rows = peers.map((p) => jsonEncode(p.toCanonicalJson())).toList()
      ..sort();
    return utf8.encode(
      [version, issuedAt.toString(), expiresAt.toString(), ...rows].join('\n'),
    );
  }

  /// Lowest locally measured RTT, then id. Unsigned RTT is not auth.
  List<DirectoryPeer> pick(DirectoryPeerKind kind) {
    final live =
        peers
            .where(
              (p) =>
                  p.kind == kind &&
                  !p.unsound &&
                  p.healthy &&
                  p.host.isNotEmpty &&
                  (p.protocols.isEmpty ||
                      p.protocols.contains(p.requiredProtocol)),
            )
            .toList()
          ..sort((a, b) {
            final byRtt = a.rttMs.compareTo(b.rttMs);
            if (byRtt != 0) return byRtt;
            return a.id.compareTo(b.id);
          });
    return live;
  }

  bool get meetsFleetMinimum =>
      pick(DirectoryPeerKind.bootstrap).length >= 3 &&
      pick(DirectoryPeerKind.relay).length >= 2 &&
      pick(DirectoryPeerKind.storage).length >= 2;

  Map<String, Object?> toJson() => <String, Object?>{
    'v': version,
    'issuedAt': issuedAt,
    'expiresAt': expiresAt,
    'peers': peers.map((p) => p.toCanonicalJson()).toList(),
    'signature': base64Encode(signature),
    'identityPublicKey': base64Encode(identityPublicKey),
  };

  static RelayDirectory fromJson(Map<String, Object?> json) {
    if (json['v'] != kRelayDirectoryInfo) {
      throw const FormatException('unsupported relay directory version');
    }
    final peers = <DirectoryPeer>[];
    final seen = <String>{};
    for (final item in json['peers'] as List? ?? const []) {
      if (item is! Map) {
        throw const FormatException('malformed directory peer');
      }
      final peer = DirectoryPeer.parse(Map<String, Object?>.from(item));
      if (!seen.add(peer.id)) {
        throw const FormatException('duplicate directory peer');
      }
      peers.add(peer);
    }
    return RelayDirectory(
      version: json['v'] as String,
      issuedAt: json['issuedAt'] as int? ?? 0,
      expiresAt: json['expiresAt'] as int? ?? 0,
      peers: peers,
      signature: Uint8List.fromList(
        base64Decode(json['signature'] as String? ?? ''),
      ),
      identityPublicKey: Uint8List.fromList(
        base64Decode(json['identityPublicKey'] as String? ?? ''),
      ),
    );
  }
}

Future<RelayDirectory> issueRelayDirectory({
  required int issuedAt,
  required int expiresAt,
  required List<DirectoryPeer> peers,
  required Uint8List identityPublicKey,
  required Future<Uint8List> Function(List<int> payload) sign,
}) async {
  final seen = <String>{};
  for (final peer in peers) {
    if (!seen.add(peer.id)) {
      throw ArgumentError('duplicate directory peer');
    }
  }
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

class RelayDirectoryVerification {
  const RelayDirectoryVerification({required this.ok, this.reason});
  final bool ok;
  final String? reason;
}

Future<RelayDirectoryVerification> verifyRelayDirectoryDetailed(
  RelayDirectory directory, {
  required List<Uint8List> trustedIdentityKeys,
  int? nowMs,
}) async {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  if (directory.version != kRelayDirectoryInfo) {
    return const RelayDirectoryVerification(
      ok: false,
      reason: 'unsupported-version',
    );
  }
  if (directory.signature.isEmpty) {
    return const RelayDirectoryVerification(ok: false, reason: 'unsigned');
  }
  if (directory.expiresAt <= directory.issuedAt) {
    return const RelayDirectoryVerification(ok: false, reason: 'malformed');
  }
  if (directory.issuedAt > now + kRelayDirectoryClockSkewMs) {
    return const RelayDirectoryVerification(ok: false, reason: 'future-dated');
  }
  if (now > directory.expiresAt) {
    return const RelayDirectoryVerification(ok: false, reason: 'expired');
  }
  final seen = <String>{};
  for (final peer in directory.peers) {
    if (!seen.add(peer.id)) {
      return const RelayDirectoryVerification(ok: false, reason: 'duplicate');
    }
    if (peer.protocols.isNotEmpty &&
        !peer.protocols.contains(peer.requiredProtocol)) {
      return const RelayDirectoryVerification(ok: false, reason: 'wrong-role');
    }
  }
  var keyMatch = false;
  for (final key in trustedIdentityKeys) {
    if (_bytesEqual(key, directory.identityPublicKey)) {
      keyMatch = true;
      break;
    }
  }
  if (!keyMatch) {
    return const RelayDirectoryVerification(
      ok: false,
      reason: 'unknown-identity',
    );
  }
  final ok = await verifyIdentitySignedBytes(
    directory.identityPublicKey,
    directory.signedPayload(),
    directory.signature,
  );
  if (!ok) {
    return const RelayDirectoryVerification(
      ok: false,
      reason: 'invalid-signature',
    );
  }
  return const RelayDirectoryVerification(ok: true);
}

Future<bool> verifyRelayDirectory(
  RelayDirectory directory, {
  List<Uint8List>? trustedIdentityKeys,
  int? nowMs,
}) async {
  final trusted = trustedIdentityKeys ?? [directory.identityPublicKey];
  final result = await verifyRelayDirectoryDetailed(
    directory,
    trustedIdentityKeys: trusted,
    nowMs: nowMs,
  );
  return result.ok;
}

/// Cached signed directory. Usable until [expiresAt], then fail closed.
class CachedRelayDirectory {
  CachedRelayDirectory({this.directory, this.cachedAt = 0});

  RelayDirectory? directory;
  int cachedAt;

  bool isLive(int nowMs) {
    final current = directory;
    if (current == null) return false;
    return nowMs <= current.expiresAt;
  }

  Future<RelayDirectory?> accept({
    required RelayDirectory incoming,
    required List<Uint8List> trustedIdentityKeys,
    required int nowMs,
  }) async {
    final verified = await verifyRelayDirectoryDetailed(
      incoming,
      trustedIdentityKeys: trustedIdentityKeys,
      nowMs: nowMs,
    );
    if (!verified.ok) return null;
    directory = incoming;
    cachedAt = nowMs;
    return incoming;
  }

  RelayDirectory? fallback(int nowMs) {
    if (!isLive(nowMs)) {
      directory = null;
      return null;
    }
    return directory;
  }
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
