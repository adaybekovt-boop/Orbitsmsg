// APNs / FCM wake payload. Must not carry message text, names, peer IDs,
// conversation IDs, or attachment metadata.

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

  static bool isSafe(Map<String, Object?> payload) {
    for (final key in payload.keys) {
      if (forbiddenKeys.contains(key)) return false;
    }
    return payload.containsKey('opaqueWakeToken') &&
        payload.containsKey('collapseId') &&
        payload.containsKey('protocolVersion');
  }
}

/// APNs/FCM extras often arrive as strings. 0 means malformed.
int opaqueWakeProtocolVersion(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim()) ?? 0;
  return 0;
}
