// Contact / room DHT topics. See docs/migration/threat-model.md.
//
// topic = HASH(domain || secret)
//
// There is intentionally no topicFromPeerId / topicFromIdentitySpki.
// A public Peer ID in the DHT lets anyone enumerate presence.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const String kContactDiscoveryInfo = 'orbits-contact-discovery-v1';
const String kRoomDiscoveryInfo = 'orbits-room-discovery-v1';
const String kReplicationDiscoveryInfo = 'orbits-replication-discovery-v1';

/// 32-byte topic from a caller-supplied shared secret.
///
/// How that secret is minted (QR invite, X3DH HKDF, capability token)
/// is a pending cryptographic review. This function only does the
/// domain-separated hash.
Future<Uint8List> contactDiscoveryTopic(List<int> sharedDiscoverySecret) {
  return _topic(kContactDiscoveryInfo, sharedDiscoverySecret);
}

Future<Uint8List> roomDiscoveryTopic(List<int> roomDiscoveryKey) {
  return _topic(kRoomDiscoveryInfo, roomDiscoveryKey);
}

Future<Uint8List> replicationDiscoveryTopic(List<int> deviceSecret) {
  return _topic(kReplicationDiscoveryInfo, deviceSecret);
}

Future<Uint8List> _topic(String info, List<int> secret) async {
  if (secret.isEmpty) {
    throw ArgumentError.value(secret, 'secret', 'must not be empty');
  }
  final h = await Sha256().hash(<int>[
    ...utf8.encode(info),
    ...secret,
  ]);
  return Uint8List.fromList(h.bytes);
}
