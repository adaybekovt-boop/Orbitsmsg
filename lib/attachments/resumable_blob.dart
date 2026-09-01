// Content-addressed chunked attachment. Per-file key wraps bytes;
// the mailbox/journal only store ciphertext + hashes.

import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

const int kAttachmentChunkSize = 64 * 1024;

class AttachmentChunk {
  const AttachmentChunk({
    required this.index,
    required this.offset,
    required this.ciphertext,
    required this.hash,
  });

  final int index;
  final int offset;
  final Uint8List ciphertext;
  final String hash;
}

class ResumableAttachment {
  ResumableAttachment({
    required this.fileId,
    required this.totalBytes,
    required this.fileKey,
    required this.chunks,
  });

  final String fileId;
  final int totalBytes;
  final List<int> fileKey;
  final List<AttachmentChunk> chunks;

  Set<int> get receivedIndexes =>
      chunks.map((c) => c.index).toSet();

  bool get isComplete {
    if (chunks.isEmpty) return totalBytes == 0;
    final expected = (totalBytes + kAttachmentChunkSize - 1) ~/
        kAttachmentChunkSize;
    return receivedIndexes.length == expected;
  }

  static List<AttachmentChunk> chunk(List<int> plaintext, List<int> fileKey) {
    final out = <AttachmentChunk>[];
    for (var offset = 0; offset < plaintext.length; offset += kAttachmentChunkSize) {
      final end = offset + kAttachmentChunkSize > plaintext.length
          ? plaintext.length
          : offset + kAttachmentChunkSize;
      final slice = plaintext.sublist(offset, end);
      final ct = _xor(slice, fileKey);
      out.add(
        AttachmentChunk(
          index: offset ~/ kAttachmentChunkSize,
          offset: offset,
          ciphertext: Uint8List.fromList(ct),
          hash: sha256.convert(ct).toString(),
        ),
      );
    }
    return out;
  }

  /// Stream plaintext from disk (or any source) without requiring a single
  /// in-memory `Uint8List` of the whole file.
  static Future<List<AttachmentChunk>> chunkFromByteStream(
    Stream<List<int>> incoming,
    List<int> fileKey,
  ) async {
    final out = <AttachmentChunk>[];
    final pending = BytesBuilder(copy: false);
    var offset = 0;
    await for (final piece in incoming) {
      pending.add(piece);
      while (pending.length >= kAttachmentChunkSize) {
        final buf = pending.takeBytes();
        final slice = buf.sublist(0, kAttachmentChunkSize);
        pending.add(buf.sublist(kAttachmentChunkSize));
        out.add(_oneChunk(offset, slice, fileKey));
        offset += slice.length;
      }
    }
    final tail = pending.takeBytes();
    if (tail.isNotEmpty) {
      out.add(_oneChunk(offset, tail, fileKey));
    }
    return out;
  }

  static AttachmentChunk _oneChunk(int offset, List<int> slice, List<int> fileKey) {
    final ct = _xor(slice, fileKey);
    return AttachmentChunk(
      index: offset ~/ kAttachmentChunkSize,
      offset: offset,
      ciphertext: Uint8List.fromList(ct),
      hash: sha256.convert(ct).toString(),
    );
  }

  static Uint8List decrypt(List<AttachmentChunk> chunks, List<int> fileKey) {
    final ordered = [...chunks]..sort((a, b) => a.index.compareTo(b.index));
    final out = BytesBuilder(copy: false);
    for (final chunk in ordered) {
      final actual = sha256.convert(chunk.ciphertext).toString();
      if (actual != chunk.hash) {
        throw StateError('attachment hash mismatch');
      }
      out.add(_xor(chunk.ciphertext, fileKey));
    }
    return out.toBytes();
  }
}

List<int> _xor(List<int> data, List<int> key) {
  if (key.isEmpty) {
    throw ArgumentError('file key required');
  }
  return List<int>.generate(
    data.length,
    (i) => data[i] ^ key[i % key.length],
  );
}
