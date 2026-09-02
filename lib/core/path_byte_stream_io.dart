// Native: stream from a local path. Never follow `://` URLs.

import 'dart:io';

int? localPathLength(String path) {
  final p = path.trim();
  if (p.isEmpty || p.contains('://')) return null;
  try {
    final file = File(p);
    if (!file.existsSync()) return null;
    final len = file.lengthSync();
    if (len <= 0) return null;
    return len;
  } catch (_) {
    return null;
  }
}

Stream<List<int>>? openLocalPathByteStream(String path) {
  final p = path.trim();
  if (p.isEmpty || p.contains('://')) return null;
  try {
    final file = File(p);
    if (!file.existsSync()) return null;
    return file.openRead();
  } catch (_) {
    return null;
  }
}
