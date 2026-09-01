// Resolve Hyperswarm bootstrap without ever falling through to the
// public DHT. Directory bootstrap rows are HyperDHT addresses, not the
// local fleet's HTTP health ports.

import 'transport_api.dart';
import 'relay_directory.dart';

const String kDhtBootstrapEnv = 'ORBITS_DHT_BOOTSTRAP';
const String kRelayDirectoryEnv = 'ORBITS_RELAY_DIRECTORY';
const String kStoragePeerOriginEnv = 'ORBITS_STORAGE_PEER_ORIGIN';

/// Hosts that would silently join Holepunch's public introducer.
bool isDeniedPublicDhtHost(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return true;
  return h == 'hyperdht.org' ||
      h.endsWith('.hyperdht.org') ||
      h == 'hypercore.io' ||
      h.endsWith('.hypercore.io') ||
      h == 'holepunch.to' ||
      h.endsWith('.holepunch.to');
}

DhtBootstrapNode? parseDhtBootstrapNode(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  String host;
  String portText;
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    if (end <= 1) return null;
    host = s.substring(1, end);
    if (end + 2 > s.length || s[end + 1] != ':') return null;
    portText = s.substring(end + 2);
  } else {
    final idx = s.lastIndexOf(':');
    if (idx <= 0 || idx == s.length - 1) return null;
    host = s.substring(0, idx);
    portText = s.substring(idx + 1);
  }
  final port = int.tryParse(portText);
  if (host.isEmpty || port == null || port <= 0 || port > 65535) {
    return null;
  }
  if (isDeniedPublicDhtHost(host)) return null;
  return DhtBootstrapNode(host: host, port: port);
}

List<DhtBootstrapNode> parseDhtBootstrapEnv(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  final out = <DhtBootstrapNode>[];
  for (final part in raw.split(',')) {
    final node = parseDhtBootstrapNode(part);
    if (node != null) out.add(node);
  }
  return out;
}

List<DhtBootstrapNode> bootstrapNodesFromDirectory(RelayDirectory directory) {
  return [
    for (final peer in directory.pick(DirectoryPeerKind.bootstrap))
      if (!isDeniedPublicDhtHost(peer.host) && peer.port > 0)
        DhtBootstrapNode(host: peer.host, port: peer.port),
  ];
}

/// Directory wins when it has usable bootstrap rows. Env is the lab
/// override. An empty result means loopback, not the public DHT.
List<DhtBootstrapNode> resolveDhtBootstrap({
  Map<String, String>? env,
  RelayDirectory? directory,
}) {
  if (directory != null) {
    final fromDir = bootstrapNodesFromDirectory(directory);
    if (fromDir.isNotEmpty) return fromDir;
  }
  return parseDhtBootstrapEnv(env?[kDhtBootstrapEnv]);
}

String? storageOriginFromPeer(DirectoryPeer peer) {
  if (peer.kind != DirectoryPeerKind.storage) return null;
  if (peer.unsound || peer.host.isEmpty || peer.port <= 0) return null;
  if (isDeniedPublicDhtHost(peer.host)) return null;
  final host = peer.host.toLowerCase();
  if (host.contains('apple.com') || host.contains('googleapis.com')) {
    return null;
  }
  return 'http://${peer.host}:${peer.port}';
}

/// Env origin first, then the lowest-RTT storage row. Not a public fleet.
String? resolveStoragePeerOrigin({
  Map<String, String>? env,
  RelayDirectory? directory,
}) {
  final explicit = env?[kStoragePeerOriginEnv];
  if (explicit != null && explicit.trim().isNotEmpty) {
    return explicit.trim();
  }
  if (directory == null) return null;
  for (final peer in directory.pick(DirectoryPeerKind.storage)) {
    final origin = storageOriginFromPeer(peer);
    if (origin != null) return origin;
  }
  return null;
}
