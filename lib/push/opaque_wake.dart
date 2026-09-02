// APNs / FCM wake payload. Must not carry message text, names, peer IDs,
// conversation IDs, attachment metadata, or Hypercore / mailbox secrets.

import 'dart:collection';

import '../transport/layers.dart';

class OpaqueWake {
  const OpaqueWake({
    required this.opaqueWakeToken,
    required this.collapseId,
    required this.protocolVersion,
  });

  final String opaqueWakeToken;
  final String collapseId;
  final int protocolVersion;

  Map<String, Object?> toJson() => <String, Object?>{
        'opaqueWakeToken': opaqueWakeToken,
        'collapseId': collapseId,
        'protocolVersion': protocolVersion,
      };

  static const forbiddenKeys = <String>{
    ...kForbiddenReplicationFields,
    'text',
    'body',
    'title',
    'senderName',
    'displayName',
    'peerId',
    'conversationId',
    'attachment',
    'mime',
    'fileName',
  };

  /// True when [payload] has the three wake fields and no [forbiddenKeys]
  /// at any depth. Walks [Map] and [Iterable] with identity-based cycle
  /// detection. Ciphertext [List<int>] and scalars are allowed.
  static bool isSafe(Map<String, Object?> payload) {
    if (_hasForbiddenKey(payload, HashSet<Object>.identity())) return false;
    return payload.containsKey('opaqueWakeToken') &&
        payload.containsKey('collapseId') &&
        payload.containsKey('protocolVersion');
  }

  static bool _hasForbiddenKey(Object? value, Set<Object> seen) {
    if (value == null || value is bool || value is num || value is String) {
      return false;
    }
    // Ciphertext bytes are leaves — do not walk them as Iterables.
    if (value is List<int>) return false;
    if (value is Map) {
      if (!seen.add(value)) return false;
      for (final entry in value.entries) {
        if (forbiddenKeys.contains('${entry.key}')) return true;
        if (_hasForbiddenKey(entry.value, seen)) return true;
      }
      return false;
    }
    if (value is Iterable) {
      if (!seen.add(value)) return false;
      for (final item in value) {
        if (_hasForbiddenKey(item, seen)) return true;
      }
      return false;
    }
    return false;
  }
}

/// APNs/FCM extras often arrive as strings. 0 means malformed.
int opaqueWakeProtocolVersion(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim()) ?? 0;
  return 0;
}
