// Phase 5: capability records ride PeerJS wireHello as a sibling field.
// They are NOT part of the identity hello blob — old clients ignore `caps`.

import 'dart:collection';

import '../peer/helpers.dart';
import 'capabilities.dart';
import 'layers.dart';
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
///
/// Fail closed: forbidden keys at any depth on the hello envelope (including
/// `caps` and sibling maps such as `extra`) drop the hello. [fromWire] already
/// refuses nested secrets inside `caps`; this walk covers the rest.
Future<CapabilityRecord?> rememberHelloCapabilities(
  String peerId,
  Map<String, Object?> hello,
) async {
  final raw = hello['caps'];
  if (raw is! Map) return null;
  try {
    final record = CapabilityRecord.fromWire(Map<String, Object?>.from(raw));
    if (_helloContainsForbiddenKeys(hello, HashSet<Object>.identity())) {
      return null;
    }
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

/// Cycle-safe walk of nested [Map] / [Iterable]. Ciphertext [List<int>]
/// is a leaf. Forbidden / wake / URL-ish keys at any depth fail closed.
/// [CapabilityRecord.peerId] is a public field and is not refused.
bool _helloContainsForbiddenKeys(Object? value, Set<Object> seen) {
  if (value == null || value is bool || value is num || value is String) {
    return false;
  }
  // Ciphertext bytes are leaves — do not walk them as Iterables.
  if (value is List<int>) return false;
  if (value is Map) {
    if (!seen.add(value)) return false;
    for (final key in value.keys) {
      final name = '$key';
      if (name == 'peerId') continue;
      if (kForbiddenReplicationFields.contains(name) ||
          name == 'opaqueWakeToken' ||
          name.contains('://')) {
        return true;
      }
    }
    for (final nested in value.values) {
      if (_helloContainsForbiddenKeys(nested, seen)) return true;
    }
    return false;
  }
  if (value is Iterable) {
    if (!seen.add(value)) return false;
    for (final item in value) {
      if (_helloContainsForbiddenKeys(item, seen)) return true;
    }
  }
  return false;
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
