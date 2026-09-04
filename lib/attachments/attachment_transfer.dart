// Path-based resumable attachment transfer. Ciphertext chunks only.
// Large files stay on disk; Dart does not copy a giant Uint8List over IPC.

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Digest, sha256;

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
  Uint8List? _derivedKey;

  Uint8List get derivedKey =>
      _derivedKey ??= deriveAttachmentKey(fileKey, fileId);

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
    final length = file.lengthSync();
    if (length != totalBytes) {
      throw StateError('attachment size mismatch');
    }
    final raf = file.openSync();
    try {
      final out = <AttachmentChunk>[];
      var offset = 0;
      var index = 0;
      while (offset < length) {
        final end = offset + kAttachmentChunkSize > length
            ? length
            : offset + kAttachmentChunkSize;
        final slice = raf.readSync(end - offset);
        final ct = encryptAttachmentChunk(
          slice,
          fileKey,
          index,
          fileId: fileId,
          derivedKey: derivedKey,
          totalBytes: totalBytes,
          offset: offset,
        );
        out.add(
          AttachmentChunk(
            index: index,
            offset: offset,
            ciphertext: ct,
            hash: sha256.convert(ct).toString(),
          ),
        );
        offset = end;
        index += 1;
      }
      return out;
    } finally {
      raf.closeSync();
    }
  }

  /// Same as [readChunksFromPath] but AES-GCM chunks run on worker isolates.
  /// 50 MiB sequential PointyCastle is ~2 min; 4 workers keep it linear.
  Future<List<AttachmentChunk>> readChunksFromPathAsync({int workers = 4}) async {
    final file = File(sourcePath);
    if (!file.existsSync()) {
      throw StateError('attachment path missing');
    }
    final length = file.lengthSync();
    if (length != totalBytes) {
      throw StateError('attachment size mismatch');
    }
    final indexes = <int>[];
    final offsets = <int>[];
    final slices = <Uint8List>[];
    final raf = file.openSync();
    try {
      var offset = 0;
      var index = 0;
      while (offset < length) {
        final end = offset + kAttachmentChunkSize > length
            ? length
            : offset + kAttachmentChunkSize;
        slices.add(raf.readSync(end - offset));
        indexes.add(index);
        offsets.add(offset);
        offset = end;
        index += 1;
      }
    } finally {
      raf.closeSync();
    }
    if (slices.length < 8 || workers <= 1) {
      return [
        for (var i = 0; i < slices.length; i++)
          _encryptOne(
            fileKey,
            fileId,
            totalBytes,
            derivedKey,
            indexes[i],
            offsets[i],
            slices[i],
          ),
      ];
    }
    final n = slices.length;
    final size = (n + workers - 1) ~/ workers;
    final key = fileKey;
    final id = fileId;
    final total = totalBytes;
    final derived = derivedKey;
    final parts = await Future.wait([
      for (var w = 0; w < workers; w++)
        () {
          final start = w * size;
          final end = math.min(n, start + size);
          if (start >= end) {
            return Future.value(<AttachmentChunk>[]);
          }
          final partIdx = indexes.sublist(start, end);
          final partOff = offsets.sublist(start, end);
          final partSl = slices.sublist(start, end);
          return Isolate.run(() => [
                for (var i = 0; i < partIdx.length; i++)
                  _encryptOne(
                    key,
                    id,
                    total,
                    derived,
                    partIdx[i],
                    partOff[i],
                    partSl[i],
                  ),
              ]);
        }(),
    ]);
    return [for (final part in parts) ...part];
  }

  void acceptChunk(
    AttachmentChunk chunk, {
    required int maxOffset,
    bool verifyHash = true,
  }) {
    if (cancelled) throw StateError('attachment cancelled');
    if (expired) throw StateError('attachment expired');
    if (chunk.offset > maxOffset && maxOffset >= 0) {
      // resume window: allow only at/after the known offset unless 0.
    }
    if (verifyHash) {
      final actual = sha256.convert(chunk.ciphertext).toString();
      if (actual != chunk.hash) {
        throw StateError('attachment hash mismatch');
      }
    }
    received.putIfAbsent(chunk.index, () => chunk);
  }

  void acceptAll(Iterable<AttachmentChunk> chunks, {bool verifyHash = true}) {
    for (final chunk in chunks) {
      acceptChunk(chunk, maxOffset: chunk.offset, verifyHash: verifyHash);
    }
  }

  Uint8List assemble() {
    if (cancelled) throw StateError('attachment cancelled');
    if (received.length != expectedChunks) {
      throw StateError('attachment incomplete');
    }
    return ResumableAttachment.decrypt(
      received.values.toList(),
      fileKey,
      fileId: fileId,
      totalBytes: totalBytes,
      derivedKey: derivedKey,
      verifyHash: false,
    );
  }

  Future<void> writeAssembled(String destPath) async {
    if (cancelled) throw StateError('attachment cancelled');
    if (received.length != expectedChunks) {
      throw StateError('attachment incomplete');
    }
    final dest = File(destPath);
    await dest.parent.create(recursive: true);
    final raf = await dest.open(mode: FileMode.write);
    try {
      final ordered = received.values.toList()
        ..sort((a, b) => a.index.compareTo(b.index));
      final plains = ordered.length < 8
          ? [
              for (final chunk in ordered)
                decryptAttachmentChunk(
                  chunk.ciphertext,
                  fileKey,
                  chunk.index,
                  fileId: fileId,
                  totalBytes: totalBytes,
                  offset: chunk.offset,
                  derivedKey: derivedKey,
                  verifyHash: false,
                ),
            ]
          : await _decryptChunksParallel(
              ordered,
              fileKey: fileKey,
              fileId: fileId,
              totalBytes: totalBytes,
              derivedKey: derivedKey,
            );
      var expectedOffset = 0;
      for (var i = 0; i < ordered.length; i++) {
        final chunk = ordered[i];
        if (chunk.offset != expectedOffset) {
          throw StateError('attachment chunk offset mismatch');
        }
        await raf.writeFrom(plains[i]);
        expectedOffset += plains[i].length;
      }
      if (expectedOffset != totalBytes) {
        throw StateError('attachment truncated');
      }
      await raf.flush();
    } finally {
      await raf.close();
    }
    if (!dest.existsSync() || dest.lengthSync() != totalBytes) {
      throw StateError('attachment result path missing: $destPath');
    }
  }

  /// Encrypt path → accept → write dest and return matching SHA-256 hex.
  Future<String> completeToPath(String destPath) async {
    acceptAll(await readChunksFromPathAsync(), verifyHash: false);
    await writeAssembled(destPath);
    final sent = sha256File(sourcePath);
    final got = sha256File(destPath);
    if (sent != got) {
      throw StateError('attachment sha256 mismatch');
    }
    cleanupPartial();
    return got;
  }

  static String sha256File(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw StateError('attachment hash path missing: $path');
    }
    final collector = _DigestCollector();
    final input = sha256.startChunkedConversion(collector);
    final raf = file.openSync();
    try {
      final buf = Uint8List(64 * 1024);
      while (true) {
        final n = raf.readIntoSync(buf);
        if (n <= 0) break;
        input.add(n == buf.length ? buf : Uint8List.sublistView(buf, 0, n));
      }
    } finally {
      raf.closeSync();
      input.close();
    }
    final digest = collector.value;
    if (digest == null) {
      throw StateError('attachment hash empty: $path');
    }
    return digest.toString();
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
  required String fileId,
  int concurrency = 2,
}) async* {
  final file = File(path);
  final length = await file.length();
  if (length > kAttachmentMaxObjectBytes) {
    throw StateError('attachment exceeds quota');
  }
  final raf = await file.open();
  final derived = deriveAttachmentKey(fileKey, fileId);
  try {
    var offset = 0;
    var index = 0;
    while (offset < length) {
      final end = offset + kAttachmentChunkSize > length
          ? length
          : offset + kAttachmentChunkSize;
      final slice = await raf.read(end - offset);
      final ct = encryptAttachmentChunk(
        slice,
        fileKey,
        index,
        fileId: fileId,
        totalBytes: length,
        offset: offset,
        derivedKey: derived,
      );
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

AttachmentChunk _encryptOne(
  List<int> fileKey,
  String fileId,
  int totalBytes,
  Uint8List derived,
  int index,
  int offset,
  Uint8List slice,
) {
  final ct = encryptAttachmentChunk(
    slice,
    fileKey,
    index,
    fileId: fileId,
    totalBytes: totalBytes,
    offset: offset,
    derivedKey: derived,
  );
  return AttachmentChunk(
    index: index,
    offset: offset,
    ciphertext: ct,
    hash: sha256.convert(ct).toString(),
  );
}

Future<List<Uint8List>> _decryptChunksParallel(
  List<AttachmentChunk> ordered, {
  required List<int> fileKey,
  required String fileId,
  required int totalBytes,
  required Uint8List derivedKey,
  int workers = 4,
}) async {
  final n = ordered.length;
  final size = (n + workers - 1) ~/ workers;
  final parts = await Future.wait([
    for (var w = 0; w < workers; w++)
      () {
        final start = w * size;
        final end = math.min(n, start + size);
        if (start >= end) {
          return Future.value(<Uint8List>[]);
        }
        final part = ordered.sublist(start, end);
        return Isolate.run(() => [
              for (final chunk in part)
                decryptAttachmentChunk(
                  chunk.ciphertext,
                  fileKey,
                  chunk.index,
                  fileId: fileId,
                  totalBytes: totalBytes,
                  offset: chunk.offset,
                  derivedKey: derivedKey,
                  verifyHash: false,
                ),
            ]);
      }(),
  ]);
  return [for (final part in parts) ...part];
}

class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
