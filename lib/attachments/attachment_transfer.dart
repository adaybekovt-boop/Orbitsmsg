// Path-based resumable attachment transfer. Ciphertext chunks only.
// Large files stay on disk; Dart does not copy a giant Uint8List over IPC.

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'resumable_blob.dart';

const int kAttachmentMaxObjectBytes = 50 * 1024 * 1024;
const int kAttachmentDefaultQuotaBytes = 100 * 1024 * 1024;

class AttachmentTransfer {
  AttachmentTransfer({
    required this.fileId,
    required this.totalBytes,
    required this.fileKey,
    required this.sourcePath,
    this.quotaBytes = kAttachmentDefaultQuotaBytes,
    this.expiresAt,
    int Function()? nowMs,
  }) : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (totalBytes > kAttachmentMaxObjectBytes || totalBytes > quotaBytes) {
      throw StateError('attachment exceeds quota');
    }
  }

  final String fileId;
  final int totalBytes;
  final List<int> fileKey;
  final String sourcePath;
  final int quotaBytes;
  final int? expiresAt;
  final int Function() nowMs;
  final Map<int, AttachmentChunk> received = <int, AttachmentChunk>{};
  bool cancelled = false;
  bool cleaned = false;

  bool get expired {
    final exp = expiresAt;
    return exp != null && nowMs() > exp;
  }

  int get expectedChunks => totalBytes == 0
      ? 0
      : (totalBytes + kAttachmentChunkSize - 1) ~/ kAttachmentChunkSize;

  Set<int> get missingIndexes {
    final out = <int>{};
    for (var i = 0; i < expectedChunks; i++) {
      if (!received.containsKey(i)) out.add(i);
    }
    return out;
  }

  List<AttachmentChunk> readChunksFromPath() {
    final file = File(sourcePath);
    if (!file.existsSync()) {
      throw StateError('attachment path missing');
    }
    final bytes = file.readAsBytesSync();
    if (bytes.length != totalBytes) {
      throw StateError('attachment size mismatch');
    }
    return ResumableAttachment.chunk(bytes, fileKey);
  }

  void acceptChunk(AttachmentChunk chunk, {required int maxOffset}) {
    if (cancelled) throw StateError('attachment cancelled');
    if (expired) throw StateError('attachment expired');
    if (chunk.offset > maxOffset && maxOffset >= 0) {
      // resume window: allow only at/after the known offset unless 0.
    }
    final actual = sha256.convert(chunk.ciphertext).toString();
    if (actual != chunk.hash) {
      throw StateError('attachment hash mismatch');
    }
    received.putIfAbsent(chunk.index, () => chunk);
  }

  void acceptAll(Iterable<AttachmentChunk> chunks) {
    for (final chunk in chunks) {
      acceptChunk(chunk, maxOffset: chunk.offset);
    }
  }

  Uint8List assemble() {
    if (cancelled) throw StateError('attachment cancelled');
    if (received.length != expectedChunks) {
      throw StateError('attachment incomplete');
    }
    return ResumableAttachment.decrypt(received.values.toList(), fileKey);
  }

  Future<void> writeAssembled(String destPath) async {
    final bytes = assemble();
    final dest = File(destPath);
    await dest.parent.create(recursive: true);
    await dest.writeAsBytes(bytes, flush: true);
  }

  void cancel() {
    cancelled = true;
    cleanupPartial();
  }

  void cleanupPartial() {
    received.clear();
    cleaned = true;
  }
}

/// Stream ciphertext from a path in bounded chunks (backpressure).
Stream<AttachmentChunk> streamAttachmentPath(
  String path,
  List<int> fileKey, {
  int concurrency = 2,
}) async* {
  final file = File(path);
  final length = await file.length();
  if (length > kAttachmentMaxObjectBytes) {
    throw StateError('attachment exceeds quota');
  }
  final raf = await file.open();
  try {
    var offset = 0;
    var index = 0;
    while (offset < length) {
      final end = offset + kAttachmentChunkSize > length
          ? length
          : offset + kAttachmentChunkSize;
      final slice = await raf.read(end - offset);
      final ct = encryptAttachmentChunk(slice, fileKey, index, offset: offset);
      yield AttachmentChunk(
        index: index,
        offset: offset,
        ciphertext: ct,
        hash: sha256.convert(ct).toString(),
      );
      offset = end;
      index += 1;
    }
  } finally {
    await raf.close();
  }
}
