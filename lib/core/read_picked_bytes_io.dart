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
