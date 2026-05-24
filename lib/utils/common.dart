// Port of src/utils/common.js — shared utility functions used across
// multiple components.
//
// `cx` is not needed in Dart (Flutter has no className concept — styling is
// via Widget trees) so it's intentionally omitted. Everything else ported.

import 'dart:convert';

/// Parse JSON from untrusted storage without throwing. Returns [fallback] for
/// null input, invalid JSON, or a parsed null.
T safeJsonParse<T>(String? value, T fallback) {
  if (value == null) return fallback;
  try {
    final parsed = jsonDecode(value);
    if (parsed == null) return fallback;
    return parsed as T;
  } catch (_) {
    return fallback;
  }
}

/// Format byte count to human-readable string (B / KB / MB / GB).
String formatSize(int? bytes) {
  if (bytes == null || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var i = 0;
  var val = bytes.toDouble();
  while (val >= 1024 && i < units.length - 1) {
    val /= 1024;
    i++;
  }
  return '${val.toStringAsFixed(i > 0 ? 1 : 0)} ${units[i]}';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Format a unix timestamp (ms) to "HH:MM" (or "HH:MM:SS" with [showSeconds]).
/// JS uses `toLocaleTimeString('ru-RU', …)` — for 24-hour clocks this produces
/// the same output regardless of locale, so we format manually to avoid the
/// `intl` dependency.
String formatTimestamp(int? ts, {bool showSeconds = false}) {
  if (ts == null || ts == 0) return '\u2014';
  final d = DateTime.fromMillisecondsSinceEpoch(ts).toLocal();
  if (showSeconds) {
    return '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
  }
  return '${_two(d.hour)}:${_two(d.minute)}';
}

/// Format a unix timestamp (ms) as a fuzzy Russian "last seen" label. Returns
/// an empty string for null/0 so callers can fall back to a generic "offline".
String formatLastSeen(int? ts, {int? now}) {
  final t = ts ?? 0;
  if (t == 0) return '';
  final currentMs = now ?? DateTime.now().millisecondsSinceEpoch;
  // Literal upper bound, not `1 << 53`: web `<<` is 32-bit and would collapse
  // it to ~2 M ms (~35 min), clamping every older "last seen" to that.
  final diff = (currentMs - t).clamp(0, 9007199254740991); // 2^53 - 1
  const min = 60 * 1000;
  const hour = 60 * min;
  const day = 24 * hour;

  if (diff < min) return 'был(а) только что';
  if (diff < hour) {
    final m = diff ~/ min;
    return 'был(а) $m мин назад';
  }
  if (diff < day) {
    final h = diff ~/ hour;
    return 'был(а) $h ч назад';
  }
  if (diff < 2 * day) return 'был(а) вчера';
  if (diff < 7 * day) {
    final d = diff ~/ day;
    return 'был(а) $d дн назад';
  }
  // Anything older than a week — absolute date, "dd MMM".
  final date = DateTime.fromMillisecondsSinceEpoch(t).toLocal();
  const months = [
    'янв', 'февр', 'мар', 'апр', 'мая', 'июн',
    'июл', 'авг', 'сент', 'окт', 'нояб', 'дек',
  ];
  return 'был(а) ${_two(date.day)} ${months[date.month - 1]}';
}

/// Format seconds to "mm:ss.t" (for voice recorder / call duration).
String formatDuration(double seconds) {
  final s = seconds < 0 ? 0 : seconds.floor();
  final mm = _two(s ~/ 60);
  final ss = _two(s % 60);
  final tenths = ((seconds - s) * 10).floor();
  return '$mm:$ss.$tenths';
}

// Allowed raster image MIME types for data-URL avatars. SVG is intentionally
// excluded: see common.js for the full security rationale (external refs,
// referer leakage, script execution in some embed contexts).
const List<String> _safeAvatarPrefixes = [
  'data:image/png;',
  'data:image/png,',
  'data:image/jpeg;',
  'data:image/jpeg,',
  'data:image/webp;',
  'data:image/webp,',
  'data:image/gif;',
  'data:image/gif,',
];

/// Validate an untrusted avatar data URL before rendering. Rejects non-data
/// URLs, SVG / unsafe MIME, and oversized payloads. Returns the original URL
/// on success, null on failure.
String? safeAvatarDataUrl(Object? raw, {int maxBytes = 512 * 1024}) {
  if (raw is! String) return null;
  if (raw.length > maxBytes) return null;
  final lower = (raw.length > 32 ? raw.substring(0, 32) : raw).toLowerCase();
  for (final prefix in _safeAvatarPrefixes) {
    if (lower.startsWith(prefix)) return raw;
  }
  return null;
}
