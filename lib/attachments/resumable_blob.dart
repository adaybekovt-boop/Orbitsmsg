// Content-addressed chunked attachment. Per-file key wraps bytes;
// the mailbox/journal only store ciphertext + hashes.

import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:pointycastle/export.dart' as pc;

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
      final index = offset ~/ kAttachmentChunkSize;
      final ct = cryptAttachmentChunk(slice, fileKey, index);
      out.add(
        AttachmentChunk(
          index: index,
          offset: offset,
          ciphertext: ct,
          hash: sha256.convert(ct).toString(),
        ),
      );
    }
    return out;
  }

  static Uint8List decrypt(List<AttachmentChunk> chunks, List<int> fileKey) {
    final ordered = [...chunks]..sort((a, b) => a.index.compareTo(b.index));
    final out = BytesBuilder(copy: false);
    for (final chunk in ordered) {
      final actual = sha256.convert(chunk.ciphertext).toString();
      if (actual != chunk.hash) {
        throw StateError('attachment hash mismatch');
      }
      out.add(cryptAttachmentChunk(chunk.ciphertext, fileKey, chunk.index));
    }
    return out.toBytes();
  }
}

/// Cryptographically secure stream cipher for attachment chunks.
/// Uses standard AES-256 in Counter (CTR) mode with a domain-separated
/// per-chunk initialization vector derived from the chunk index.
Uint8List cryptAttachmentChunk(List<int> data, List<int> key, int chunkIndex) {
  if (key.isEmpty) {
    throw ArgumentError('file key required');
  }
  final aesKey = Uint8List.fromList(sha256.convert(key).bytes);
  final ivData = Uint8List(16);
  final bd = ByteData.sublistView(ivData);
  bd.setUint32(0, 0x4f424154); // 'OBAT'
  bd.setUint64(8, chunkIndex);
  final iv = Uint8List.fromList(sha256.convert(ivData).bytes.sublist(0, 16));

  final cipher = pc.SICStreamCipher(pc.AESEngine())
    ..init(
      true,
      pc.ParametersWithIV(pc.KeyParameter(aesKey), iv),
    );
  return cipher.process(Uint8List.fromList(data));
}
