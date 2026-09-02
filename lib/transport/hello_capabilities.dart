// Phase 5: capability records ride PeerJS wireHello as a sibling field.
// They are NOT part of the identity hello blob — old clients ignore `caps`.

import '../peer/helpers.dart';
import 'capabilities.dart';
import 'signed_capabilities.dart';

class RemoteCapabilityCache {
  final Map<String, CapabilityRecord> _byPeer = <String, CapabilityRecord>{};

  void put(String peerId, CapabilityRecord record) {
    _byPeer[normalizePeerId(peerId)] = record;
  }

  CapabilityRecord? get(String peerId) => _byPeer[normalizePeerId(peerId)];

  void remove(String peerId) => _byPeer.remove(normalizePeerId(peerId));

  void clear() => _byPeer.clear();
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
    if (!await verifyCapabilityRecord(record)) return null;
    if (record.peerId.isNotEmpty &&
        normalizePeerId(record.peerId) != normalizePeerId(peerId)) {
      return null;
    }
    remoteCapabilityCache.put(peerId, record);
    return record;
  } catch (_) {
    return null;
  }
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

/// Sorted wire names for [DeviceBinding.capabilities]. Never URLs.
List<String> advertisedLocalCapabilityWireNames() {
  final names = advertisedLocalCapabilities().map((c) => c.wireName).toList()
    ..sort();
  return names;
}
