// Native: stream from a local path. Never follow `://` URLs.

import 'dart:io';

import '../attachments/resumable_blob.dart';
import 'path_byte_stream.dart';

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

Future<CipherPathWrite?> xorPlaintextPathToCipherFile(
  String plaintextPath,
  List<int> fileKey,
) async {
  final p = plaintextPath.trim();
  if (p.isEmpty || p.contains('://') || fileKey.isEmpty) return null;
  final src = File(p);
  if (!src.existsSync()) return null;
  Directory? dir;
  IOSink? sink;
  try {
    dir = Directory.systemTemp.createTempSync('orbits-att-ct-');
    final dest = File('${dir.path}${Platform.pathSeparator}cipher.bin');
    sink = dest.openWrite();
    List<int>? first;
    var count = 0;
    var total = 0;
    await for (final chunk
        in ResumableAttachment.chunkStream(src.openRead(), fileKey)) {
      sink.add(chunk.ciphertext);
      first ??= List<int>.from(chunk.ciphertext);
      count++;
      total += chunk.ciphertext.length;
    }
    await sink.close();
    sink = null;
    if (first == null || total <= 0) {
      dir.deleteSync(recursive: true);
      return null;
    }
    final captured = dir;
    return CipherPathWrite(
      path: dest.path,
      sizeBytes: total,
      firstCipher: first,
      chunkCount: count,
      dispose: () {
        try {
          if (captured.existsSync()) captured.deleteSync(recursive: true);
        } catch (_) {}
      },
    );
  } catch (_) {
    try {
      await sink?.close();
    } catch (_) {}
    try {
      dir?.deleteSync(recursive: true);
    } catch (_) {}
    return null;
  }
}
