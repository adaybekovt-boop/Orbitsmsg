/// Wire / meta transfer ids. Never used as a path fragment until
/// [sanitizeTransferId] has stripped separators. Not a discovery secret.

final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
final _unsafe = RegExp(r'[^A-Za-z0-9._-]');

/// Fold chat `msgId` (`ORBIT-…:ts:short`) and any other external id
/// into a path-safe token. Same alphabet as [assertSafePathFragment].
String sanitizeTransferId(String raw) {
  final cleaned = raw.trim().replaceAll(_unsafe, '_');
  if (cleaned.isEmpty || cleaned.contains('..') || !_safeId.hasMatch(cleaned)) {
    throw StateError('unsafe-transfer-id');
  }
  return cleaned;
}

String? trySanitizeTransferId(String raw) {
  try {
    return sanitizeTransferId(raw);
  } catch (_) {
    return null;
  }
}

bool transferIdsMatch(String? a, String? b) {
  if (a == null || b == null) return false;
  final left = trySanitizeTransferId(a);
  final right = trySanitizeTransferId(b);
  return left != null && left == right;
}
