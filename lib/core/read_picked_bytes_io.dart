// Native: prefer a path. Stat length first, refuse over the cap, then
// read through RandomAccessFile. Never load an uncapped file into a
// Dart list before that check.

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'read_picked_bytes.dart';

Future<PickedBytesResult> readPickedBytes(
  PlatformFile file, {
  required int maxRawBytes,
}) async {
  final existing = file.bytes;
  if (existing != null && existing.isNotEmpty) {
    if (existing.length > maxRawBytes) {
      return PickedBytesResult.tooLarge(existing.length);
    }
    return PickedBytesResult.ok(existing);
  }
  final path = file.path;
  if (path == null || path.isEmpty) return const PickedBytesResult.empty();
  try {
    final ioFile = File(path);
    if (!await ioFile.exists()) return const PickedBytesResult.empty();
    final len = await ioFile.length();
    if (len <= 0) return const PickedBytesResult.empty();
    if (len > maxRawBytes) return PickedBytesResult.tooLarge(len);
    final RandomAccessFile raf = await ioFile.open();
    try {
      final bytes = Uint8List(len);
      var offset = 0;
      while (offset < len) {
        final n = await raf.readInto(bytes, offset);
        if (n <= 0) break;
        offset += n;
      }
      if (offset != len) return const PickedBytesResult.empty();
      return PickedBytesResult.ok(bytes);
    } finally {
      await raf.close();
    }
  } catch (_) {
    return const PickedBytesResult.empty();
  }
}

Future<MaterializedPick> materializePickedLocalPath(
  PlatformFile file, {
  required int maxBytes,
}) async {
  final path = file.path;
  if (path != null && path.isNotEmpty && !path.contains('://')) {
    try {
      final ioFile = File(path);
      if (await ioFile.exists()) {
        final len = await ioFile.length();
        if (len <= 0) return const MaterializedPick.empty();
        if (len > maxBytes) return MaterializedPick.tooLarge(len);
        return MaterializedPick.ok(path, len);
      }
    } catch (_) {}
  }
  final existing = file.bytes;
  if (existing != null && existing.isNotEmpty) {
    if (existing.length > maxBytes) {
      return MaterializedPick.tooLarge(existing.length);
    }
    final written = await _writeBytesToTemp(existing, file.name);
    if (written == null) return const MaterializedPick.empty();
    return MaterializedPick.ok(written, existing.length);
  }
  final stream = file.readStream;
  if (stream == null) return const MaterializedPick.empty();
  return _writeStreamToTemp(stream, file.name, maxBytes);
}

String _safePickName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty || trimmed.contains('://')) return 'picked.bin';
  final slash = trimmed.replaceAll('\\', '/');
  final base = slash.split('/').last;
  if (base.isEmpty || base.contains('://')) return 'picked.bin';
  return base;
}

Future<String?> _writeBytesToTemp(List<int> bytes, String name) async {
  try {
    final dir = await Directory.systemTemp.createTemp('orbits-pick-');
    if (dir.path.contains('://')) return null;
    final dest = File('${dir.path}${Platform.pathSeparator}${_safePickName(name)}');
    await dest.writeAsBytes(bytes, flush: true);
    return dest.path;
  } catch (_) {
    return null;
  }
}

Future<MaterializedPick> _writeStreamToTemp(
  Stream<List<int>> stream,
  String name,
  int maxBytes,
) async {
  Directory? dir;
  IOSink? sink;
  try {
    dir = await Directory.systemTemp.createTemp('orbits-pick-');
    if (dir.path.contains('://')) return const MaterializedPick.empty();
    final dest = File('${dir.path}${Platform.pathSeparator}${_safePickName(name)}');
    sink = dest.openWrite();
    var size = 0;
    await for (final chunk in stream) {
      size += chunk.length;
      if (size > maxBytes) {
        await sink.close();
        try {
          await dest.delete();
        } catch (_) {}
        return MaterializedPick.tooLarge(size);
      }
      sink.add(chunk);
    }
    await sink.flush();
    await sink.close();
    sink = null;
    if (size <= 0) return const MaterializedPick.empty();
    return MaterializedPick.ok(dest.path, size);
  } catch (_) {
    try {
      await sink?.close();
    } catch (_) {}
    return const MaterializedPick.empty();
  }
}
