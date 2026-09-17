// Native: stream from a local path. Never follow `://` URLs.

import 'dart:io';
import 'dart:typed_data';

import '../attachments/path_attachment.dart';
import '../attachments/resumable_blob.dart';
import 'orbits_drop.dart' show sanitizeDropFileName;
import 'path_byte_stream.dart';

final Map<String, IncomingPathAttachment> _inboundCipher = <String, IncomingPathAttachment>{};

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

Future<List<int>?> xorCipherPathToPlaintext(
  String cipherPath,
  List<int> fileKey,
) async {
  final p = cipherPath.trim();
  if (p.isEmpty || p.contains('://') || fileKey.isEmpty) return null;
  final src = File(p);
  if (!src.existsSync()) return null;
  const maxBytes = kMaxNativeAttachBytes;
  try {
    if (src.lengthSync() > maxBytes || src.lengthSync() <= 0) return null;
  } catch (_) {
    return null;
  }
  final out = BytesBuilder(copy: true);
  var i = 0;
  try {
    await for (final piece in src.openRead()) {
      if (piece.isEmpty) continue;
      if (out.length + piece.length > maxBytes) return null;
      final dst = Uint8List(piece.length);
      for (var j = 0; j < piece.length; j++) {
        dst[j] = piece[j] ^ fileKey[i % fileKey.length];
        i++;
      }
      out.add(dst);
    }
  } catch (_) {
    return null;
  }
  if (out.isEmpty) return null;
  return out.takeBytes();
}

Future<String?> xorCipherPathToPlaintextFile(
  String cipherPath,
  List<int> fileKey,
) async {
  final p = cipherPath.trim();
  if (p.isEmpty || p.contains('://') || fileKey.isEmpty) return null;
  final src = File(p);
  if (!src.existsSync()) return null;
  const maxBytes = kMaxNativeAttachBytes;
  try {
    if (src.lengthSync() > maxBytes || src.lengthSync() <= 0) return null;
  } catch (_) {
    return null;
  }
  Directory? dir;
  IOSink? sink;
  try {
    dir = Directory.systemTemp.createTempSync('orbits-att-pt-');
    final dest = File('${dir.path}${Platform.pathSeparator}plain.bin');
    sink = dest.openWrite();
    var i = 0;
    var total = 0;
    await for (final piece in src.openRead()) {
      if (piece.isEmpty) continue;
      if (total + piece.length > maxBytes) {
        throw StateError('cipher path exceeds cap');
      }
      final dst = Uint8List(piece.length);
      for (var j = 0; j < piece.length; j++) {
        dst[j] = piece[j] ^ fileKey[i % fileKey.length];
        i++;
      }
      sink.add(dst);
      total += dst.length;
    }
    await sink.close();
    sink = null;
    if (total <= 0) {
      dir.deleteSync(recursive: true);
      return null;
    }
    return dest.path;
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

Future<String?> copyLocalPathToStableFile(
  String srcPath,
  String destDirectory, {
  String fileName = 'plain.bin',
}) async {
  final p = srcPath.trim();
  final destRoot = destDirectory.trim();
  final name = fileName.trim();
  if (p.isEmpty ||
      destRoot.isEmpty ||
      name.isEmpty ||
      p.contains('://') ||
      destRoot.contains('://') ||
      name.contains('://') ||
      name.contains('/') ||
      name.contains('\\') ||
      name.contains('fileKey') ||
      name.contains('peerId')) {
    return null;
  }
  final src = File(p);
  if (!src.existsSync()) return null;
  const maxBytes = kMaxNativeAttachBytes;
  try {
    if (src.lengthSync() > maxBytes || src.lengthSync() <= 0) return null;
  } catch (_) {
    return null;
  }
  Directory? sub;
  IOSink? sink;
  try {
    final root = Directory(destRoot);
    if (!root.existsSync()) root.createSync(recursive: true);
    sub = root.createTempSync('att-');
    final dest = File('${sub.path}${Platform.pathSeparator}$name');
    sink = dest.openWrite();
    var total = 0;
    await for (final piece in src.openRead()) {
      if (piece.isEmpty) continue;
      if (total + piece.length > maxBytes) {
        throw StateError('copy exceeds cap');
      }
      sink.add(piece);
      total += piece.length;
    }
    await sink.close();
    sink = null;
    if (total <= 0) {
      sub.deleteSync(recursive: true);
      return null;
    }
    return dest.path;
  } catch (_) {
    try {
      await sink?.close();
    } catch (_) {}
    try {
      sub?.deleteSync(recursive: true);
    } catch (_) {}
    return null;
  }
}

Future<String?> writeBytesToTempPath(
  List<int> bytes, {
  String fileName = 'plain.bin',
  int maxBytes = 50 * 1024 * 1024,
}) async {
  if (bytes.isEmpty || bytes.length > maxBytes) return null;
  final name = sanitizeDropFileName(fileName);
  if (name.contains('://') || name.contains('fileKey') || name.contains('peerId')) {
    return null;
  }
  try {
    final dir = Directory.systemTemp.createTempSync('orbits-bytes-');
    if (dir.path.contains('://')) return null;
    final dest = File('${dir.path}${Platform.pathSeparator}$name');
    final sink = dest.openWrite();
    try {
      sink.add(bytes);
      await sink.flush();
      await sink.close();
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
      return null;
    }
    return dest.path;
  } catch (_) {
    return null;
  }
}

Future<String?> openInboundCipherPath(String fileId) async {
  final id = fileId.trim();
  if (id.isEmpty || id.contains('://')) return null;
  final existing = _inboundCipher[id];
  if (existing != null) return existing.path;
  try {
    final incoming = await IncomingPathAttachment.open(
      id: sanitizeDropFileName(id),
      name: 'cipher.bin',
      totalBytes: kMaxNativeAttachBytes,
      sha256hex: '',
    );
    _inboundCipher[id] = incoming;
    return incoming.path;
  } catch (_) {
    return null;
  }
}

Future<bool> writeInboundCipherChunk(
  String fileId,
  int offset,
  List<int> bytes,
) async {
  final id = fileId.trim();
  if (id.isEmpty || id.contains('://') || bytes.isEmpty) return false;
  if (offset < 0 || offset + bytes.length > kMaxNativeAttachBytes) {
    return false;
  }
  var incoming = _inboundCipher[id];
  if (incoming == null) {
    final path = await openInboundCipherPath(id);
    if (path == null) return false;
    incoming = _inboundCipher[id];
  }
  if (incoming == null) return false;
  try {
    await incoming.writeChunk(offset, bytes);
    return true;
  } catch (_) {
    return false;
  }
}
