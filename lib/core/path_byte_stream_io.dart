// Native: stream from a local path. Never follow `://` URLs.

import 'dart:io';
import 'dart:typed_data';

import '../attachments/attachment_aead.dart';
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

Future<CipherPathWrite?> sealPlaintextPathToCipherFile(
  String plaintextPath,
  List<int> fileKey, {
  required String scope,
  required String fileId,
}) async {
  final p = plaintextPath.trim();
  if (p.isEmpty ||
      p.contains('://') ||
      fileKey.length != kNativeAttachFileKeyBytes ||
      scope.contains('://') ||
      fileId.contains('://') ||
      fileId.isEmpty) {
    return null;
  }
  final src = File(p);
  if (!src.existsSync()) return null;
  final int totalBytes;
  try {
    totalBytes = src.lengthSync();
  } catch (_) {
    return null;
  }
  if (totalBytes < 0 || totalBytes > kMaxNativeAttachBytes) return null;
  Directory? dir;
  IOSink? sink;
  try {
    dir = Directory.systemTemp.createTempSync('orbits-att-ct-');
    final dest = File('${dir.path}${Platform.pathSeparator}cipher.bin');
    sink = dest.openWrite();
    List<int>? first;
    var count = 0;
    var total = 0;
    await for (final chunk in ResumableAttachment.chunkStream(
      src.openRead(),
      fileKey,
      scope: scope,
      fileId: fileId,
      totalBytes: totalBytes,
    )) {
      sink.add(chunk.ciphertext);
      first ??= List<int>.from(chunk.ciphertext);
      count++;
      total += chunk.ciphertext.length;
    }
    await sink.close();
    sink = null;
    if (first == null || count <= 0) {
      dir.deleteSync(recursive: true);
      return null;
    }
    final captured = dir;
    return CipherPathWrite(
      path: dest.path,
      sizeBytes: total,
      plaintextBytes: totalBytes,
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

Future<List<int>?> openCipherPathToPlaintext(
  String cipherPath,
  List<int> fileKey, {
  required String scope,
  required String fileId,
  int? totalBytes,
}) async {
  final p = cipherPath.trim();
  if (p.isEmpty ||
      p.contains('://') ||
      fileKey.length != kNativeAttachFileKeyBytes ||
      scope.contains('://') ||
      fileId.contains('://') ||
      fileId.isEmpty) {
    return null;
  }
  final src = File(p);
  if (!src.existsSync()) return null;
  final cap = attachmentCipherCapBytes(plaintextCap: kMaxNativeAttachBytes);
  final int len;
  try {
    len = src.lengthSync();
    if (len <= 0 || len > cap) return null;
  } catch (_) {
    return null;
  }
  final resolved = totalBytes ?? inferAttachmentPlaintextBytes(len);
  if (resolved == null || resolved < 0 || resolved > kMaxNativeAttachBytes) {
    return null;
  }
  final out = BytesBuilder(copy: true);
  try {
    await for (final piece in _openEnvelopeStream(
      src.openRead(),
      fileKey: fileKey,
      scope: scope,
      fileId: fileId,
      totalBytes: resolved,
    )) {
      if (out.length + piece.length > kMaxNativeAttachBytes) {
        return null;
      }
      out.add(piece);
    }
  } catch (_) {
    return null;
  }
  if (out.length != resolved) return null;
  return out.takeBytes();
}

Future<String?> openCipherPathToPlaintextFile(
  String cipherPath,
  List<int> fileKey, {
  required String scope,
  required String fileId,
  int? totalBytes,
}) async {
  final p = cipherPath.trim();
  if (p.isEmpty ||
      p.contains('://') ||
      fileKey.length != kNativeAttachFileKeyBytes ||
      scope.contains('://') ||
      fileId.contains('://') ||
      fileId.isEmpty) {
    return null;
  }
  final src = File(p);
  if (!src.existsSync()) return null;
  final cap = attachmentCipherCapBytes(plaintextCap: kMaxNativeAttachBytes);
  final int len;
  try {
    len = src.lengthSync();
    if (len <= 0 || len > cap) return null;
  } catch (_) {
    return null;
  }
  final resolved = totalBytes ?? inferAttachmentPlaintextBytes(len);
  if (resolved == null || resolved < 0 || resolved > kMaxNativeAttachBytes) {
    return null;
  }
  Directory? dir;
  IOSink? sink;
  try {
    dir = Directory.systemTemp.createTempSync('orbits-att-pt-');
    final dest = File('${dir.path}${Platform.pathSeparator}plain.bin');
    sink = dest.openWrite();
    var total = 0;
    await for (final piece in _openEnvelopeStream(
      src.openRead(),
      fileKey: fileKey,
      scope: scope,
      fileId: fileId,
      totalBytes: resolved,
    )) {
      if (total + piece.length > kMaxNativeAttachBytes) {
        throw StateError('cipher path exceeds cap');
      }
      sink.add(piece);
      total += piece.length;
    }
    await sink.close();
    sink = null;
    if (total != resolved) {
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

/// Parse concatenated `version||nonce||ct||tag` envelopes. Each chunk is
/// 64 KiB plaintext except the last. Duplicate nonces fail closed.
Stream<Uint8List> _openEnvelopeStream(
  Stream<List<int>> incoming, {
  required List<int> fileKey,
  required String scope,
  required String fileId,
  required int totalBytes,
}) async* {
  final pending = BytesBuilder(copy: false);
  final nonces = AttachmentNonceTracker();
  var offset = 0;
  var index = 0;
  var emitted = 0;
  await for (final piece in incoming) {
    if (piece.isEmpty) continue;
    pending.add(piece);
    while (true) {
      final remaining = totalBytes - offset;
      final ptLen = totalBytes == 0
          ? 0
          : (remaining < kAttachmentChunkSize
                ? remaining
                : kAttachmentChunkSize);
      if (totalBytes == 0 && emitted > 0) {
        if (pending.length == 0) return;
        throw AttachmentAeadError('trailing ciphertext');
      }
      if (totalBytes > 0 && offset >= totalBytes) {
        if (pending.length == 0) return;
        throw AttachmentAeadError('trailing ciphertext');
      }
      final need = kAttachmentAeadOverhead + ptLen;
      if (pending.length < need) break;
      final buf = pending.takeBytes();
      final envelope = buf.sublist(0, need);
      if (buf.length > need) pending.add(buf.sublist(need));
      final nonce = attachmentEnvelopeNonce(envelope);
      if (nonce == null || !nonces.remember(nonce)) {
        throw AttachmentAeadError('replayed nonce');
      }
      final plain = decryptChunk(
        envelope: envelope,
        fileKey: fileKey,
        scope: scope,
        fileId: fileId,
        index: index,
        offset: offset,
        totalBytes: totalBytes,
      );
      if (plain.length != ptLen) {
        throw AttachmentAeadError('chunk length mismatch');
      }
      yield plain;
      emitted++;
      offset += ptLen;
      index++;
      if (totalBytes == 0) {
        if (pending.length == 0) return;
        throw AttachmentAeadError('trailing ciphertext');
      }
    }
  }
  if (emitted == 0 ||
      (totalBytes > 0 && offset != totalBytes) ||
      pending.length > 0) {
    throw AttachmentAeadError('truncated ciphertext');
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

Future<void> deleteOrbitsAttPlaintextSource(String path) async {
  final p = path.trim();
  if (p.isEmpty || p.contains('://')) return;
  final file = File(p);
  final dir = file.existsSync() ? file.parent : Directory(p);
  final parts = dir.path.split(Platform.pathSeparator)
      .where((s) => s.isNotEmpty)
      .toList();
  final base = parts.isEmpty ? dir.path : parts.last;
  if (!base.startsWith('orbits-att-pt-')) return;
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {}
}
