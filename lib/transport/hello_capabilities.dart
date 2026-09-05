// Phase 5: capability records ride PeerJS wireHello as a sibling field.
// They are NOT part of the identity hello blob — old clients ignore `caps`.

import 'dart:convert';

import '../peer/helpers.dart';
import 'capabilities.dart';
import 'signed_capabilities.dart';

class RemoteCapabilityCache {
  final Map<String, CapabilityRecord> _byPeer = <String, CapabilityRecord>{};
  final Set<String> _seenSignatures = <String>{};
  final Set<String> _revokedPeers = <String>{};
  final Set<String> _forbidFallback = <String>{};

  void put(String peerId, CapabilityRecord record) {
    _byPeer[normalizePeerId(peerId)] = record;
  }

  CapabilityRecord? get(String peerId) => _byPeer[normalizePeerId(peerId)];

  void remove(String peerId) => _byPeer.remove(normalizePeerId(peerId));

  void revoke(String peerId) {
    final id = normalizePeerId(peerId);
    _revokedPeers.add(id);
    _byPeer.remove(id);
  }

  void forbidFallback(String peerId) =>
      _forbidFallback.add(normalizePeerId(peerId));

  bool fallbackForbidden(String peerId) =>
      _forbidFallback.contains(normalizePeerId(peerId));

  bool isRevoked(String peerId) =>
      _revokedPeers.contains(normalizePeerId(peerId));

  bool rememberSignature(List<int> signature) {
    final key = base64Encode(signature);
    return _seenSignatures.add(key);
  }

  void clear() {
    _byPeer.clear();
    _seenSignatures.clear();
    _revokedPeers.clear();
    _forbidFallback.clear();
  }
}

final remoteCapabilityCache = RemoteCapabilityCache();

/// Verify and remember a `caps` object from an incoming hello. Invalid or
/// unsigned records are dropped; the handshake still completes.
Future<CapabilityRecord?> rememberHelloCapabilities(
  String peerId,
  Map<String, Object?> hello,
) async {
  final raw = hello['caps'];
  if (raw is! Map) return null;
  try {
    final record = CapabilityRecord.fromWire(Map<String, Object?>.from(raw));
    if (remoteCapabilityCache.isRevoked(peerId)) return null;
    if (!await verifyCapabilityRecord(record)) return null;
    if (record.peerId.isNotEmpty &&
        normalizePeerId(record.peerId) != normalizePeerId(peerId)) {
      return null;
    }
    if (!remoteCapabilityCache.rememberSignature(record.signature)) {
      return null;
    }
    remoteCapabilityCache.put(peerId, record);
    return record;
  } catch (_) {
    return null;
  }
}

/// A later hello that drops `caps` after we already cached a record is a
/// strip attempt. Old clients that never sent caps are unchanged.
bool capabilityWasStripped(String peerId, Map<String, Object?> hello) {
  if (hello['caps'] != null) return false;
  return remoteCapabilityCache.get(peerId) != null;
}

Future<Map<String, Object?>?> localHelloCapabilities({
  required String peerId,
  required String deviceId,
}) async {
  try {
    final record = await issueLocalCapabilityRecord(
      peerId: peerId,
      deviceId: deviceId,
      capabilities: advertisedLocalCapabilities(),
      issuedAt: DateTime.now().millisecondsSinceEpoch,
      expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000 * 30,
    );
    return record.toWire();
  } catch (_) {
    return null;
  }
}

Set<TransportCapability> advertisedLocalCapabilities() => {
  TransportCapability.peerjsV4,
  TransportCapability.hyperswarmV1,
  TransportCapability.mailboxV1,
  TransportCapability.hypercoreV1,
  TransportCapability.multiDeviceV1,
};
