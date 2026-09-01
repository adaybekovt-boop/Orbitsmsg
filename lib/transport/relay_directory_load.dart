// Load a local relay directory file. Never fetches a URL. A verified
// signature does not mean a public fleet exists.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dht_bootstrap.dart';
import 'relay_directory.dart';

RelayDirectory relayDirectoryFromJson(Map<String, Object?> json) {
  final peers = <DirectoryPeer>[];
  final rawPeers = json['peers'];
  if (rawPeers is List) {
    for (final item in rawPeers) {
      if (item is Map) {
        peers.add(DirectoryPeer.fromJson(Map<String, Object?>.from(item)));
      }
    }
  }
  return RelayDirectory(
    issuedAt: _asInt(json['issuedAt']),
    expiresAt: _asInt(json['expiresAt']),
    peers: peers,
    signature: _b64(json['signature']),
    identityPublicKey: _b64(json['identityPublicKey']),
  );
}

Map<String, Object?> relayDirectoryToJson(RelayDirectory directory) =>
    <String, Object?>{
      'issuedAt': directory.issuedAt,
      'expiresAt': directory.expiresAt,
      'peers': directory.peers.map((p) => p.toJson()).toList(),
      'signature': base64Encode(directory.signature),
      'identityPublicKey': base64Encode(directory.identityPublicKey),
    };

bool relayDirectoryIsUnsignedLab(RelayDirectory directory) =>
    directory.signature.isEmpty;

/// File path only. `http://` / `https://` is refused so Dart cannot
/// download a directory.
Future<RelayDirectory?> loadRelayDirectoryFile(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return null;
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return null;
  }
  final file = File(trimmed);
  if (!file.existsSync()) return null;
  late final Map<String, Object?> json;
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    json = Map<String, Object?>.from(decoded);
  } catch (_) {
    return null;
  }
  final directory = relayDirectoryFromJson(json);
  if (directory.peers.isEmpty) return null;
  if (relayDirectoryIsUnsignedLab(directory)) {
    // Lab fixture. Not a live signed directory.
    if (kLiveSignedRelayDirectory) return null;
    return directory;
  }
  if (!await verifyRelayDirectory(directory)) return null;
  return directory;
}

Future<RelayDirectory?> loadRelayDirectoryFromEnv({
  Map<String, String>? env,
}) async {
  final path = (env ?? Platform.environment)[kRelayDirectoryEnv];
  if (path == null || path.isEmpty) return null;
  return loadRelayDirectoryFile(path);
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

Uint8List _b64(Object? value) {
  if (value is! String || value.isEmpty) return Uint8List(0);
  try {
    return Uint8List.fromList(base64Decode(value));
  } catch (_) {
    return Uint8List(0);
  }
}
