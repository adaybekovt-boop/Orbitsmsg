// Content-addressed chunked attachment. Per-file AES-256-GCM.
// The mailbox/journal only store ciphertext + hashes.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:pointycastle/export.dart' as pc;

const int kAttachmentChunkSize = 64 * 1024;
const int kAttachmentTagSize = 16;
const int kAttachmentProtocolVersion = 2;
const String kAttachmentKdfInfoEnc = 'orbits-attach-enc-v2';
const String kAttachmentKdfInfoNonce = 'orbits-attach-nonce-v2';

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

  Set<int> get receivedIndexes => chunks.map((c) => c.index).toSet();

  bool get isComplete {
    if (chunks.isEmpty) return totalBytes == 0;
    final expected =
        (totalBytes + kAttachmentChunkSize - 1) ~/ kAttachmentChunkSize;
    return receivedIndexes.length == expected;
  }

  static List<AttachmentChunk> chunk(
    List<int> plaintext,
    List<int> fileKey, {
    required String fileId,
    int? totalBytes,
  }) {
    final total = totalBytes ?? plaintext.length;
    final out = <AttachmentChunk>[];
    for (
      var offset = 0;
      offset < plaintext.length;
      offset += kAttachmentChunkSize
    ) {
      final end = offset + kAttachmentChunkSize > plaintext.length
          ? plaintext.length
          : offset + kAttachmentChunkSize;
      final slice = plaintext.sublist(offset, end);
      final index = offset ~/ kAttachmentChunkSize;
      final ct = encryptAttachmentChunk(
        slice,
        fileKey,
        index,
        fileId: fileId,
        totalBytes: total,
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
    }
    return out;
  }

  static Uint8List decrypt(
    List<AttachmentChunk> chunks,
    List<int> fileKey, {
    required String fileId,
    required int totalBytes,
  }) {
    final ordered = [...chunks]..sort((a, b) => a.index.compareTo(b.index));
    final seen = <int>{};
    final out = BytesBuilder(copy: false);
    var expectedOffset = 0;
    for (final chunk in ordered) {
      if (!seen.add(chunk.index)) {
        throw StateError('duplicate attachment chunk');
      }
      if (chunk.index != seen.length - 1) {
        throw StateError('reordered or missing attachment chunk');
      }
      if (chunk.offset != expectedOffset) {
        throw StateError('attachment chunk offset mismatch');
      }
      final actual = sha256.convert(chunk.ciphertext).toString();
      if (actual != chunk.hash) {
        throw StateError('attachment hash mismatch');
      }
      final plain = decryptAttachmentChunk(
        chunk.ciphertext,
        fileKey,
        chunk.index,
        fileId: fileId,
        totalBytes: totalBytes,
        offset: chunk.offset,
      );
      out.add(plain);
      expectedOffset += plain.length;
    }
    if (expectedOffset != totalBytes) {
      throw StateError('attachment truncated');
    }
    return out.toBytes();
  }
}

Uint8List deriveAttachmentKey(List<int> fileKey, String fileId) {
  if (fileKey.isEmpty) {
    throw ArgumentError('file key required');
  }
  final hmac = Hmac(sha256, fileKey);
  return Uint8List.fromList(
    hmac.convert(utf8.encode('$kAttachmentKdfInfoEnc|$fileId')).bytes,
  );
}

Uint8List attachmentNonce(String fileId, int chunkIndex, int offset) {
  final hmac = Hmac(sha256, utf8.encode(kAttachmentKdfInfoNonce));
  final digest = hmac.convert(utf8.encode('$fileId|$chunkIndex|$offset')).bytes;
  return Uint8List.fromList(digest.sublist(0, 12));
}

Uint8List attachmentAad({
  required String fileId,
  required int totalBytes,
  required int chunkIndex,
  required int offset,
  int protocolVersion = kAttachmentProtocolVersion,
}) {
  final id = utf8.encode(fileId);
  final out = ByteData(4 + 4 + 8 + 8 + 8 + id.length);
  var o = 0;
  out.setUint32(o, protocolVersion);
  o += 4;
  out.setUint32(o, id.length);
  o += 4;
  out.setUint64(o, totalBytes);
  o += 8;
  out.setUint64(o, chunkIndex);
  o += 8;
  out.setUint64(o, offset);
  final bytes = out.buffer.asUint8List();
  bytes.setAll(4 + 4 + 8 + 8 + 8, id);
  return bytes;
}

Uint8List encryptAttachmentChunk(
  List<int> data,
  List<int> key,
  int chunkIndex, {
  required String fileId,
  required int totalBytes,
  int offset = 0,
}) {
  final encKey = deriveAttachmentKey(key, fileId);
  final nonce = attachmentNonce(fileId, chunkIndex, offset);
  final aad = attachmentAad(
    fileId: fileId,
    totalBytes: totalBytes,
    chunkIndex: chunkIndex,
    offset: offset,
  );
  final cipher = pc.GCMBlockCipher(pc.AESEngine())
    ..init(true, pc.AEADParameters(pc.KeyParameter(encKey), 128, nonce, aad));
  return cipher.process(Uint8List.fromList(data));
}

Uint8List decryptAttachmentChunk(
  List<int> data,
  List<int> key,
  int chunkIndex, {
  required String fileId,
  required int totalBytes,
  int offset = 0,
}) {
  if (data.length < kAttachmentTagSize) {
    throw StateError('attachment chunk too short for AEAD tag');
  }
  final encKey = deriveAttachmentKey(key, fileId);
  final nonce = attachmentNonce(fileId, chunkIndex, offset);
  final aad = attachmentAad(
    fileId: fileId,
    totalBytes: totalBytes,
    chunkIndex: chunkIndex,
    offset: offset,
  );
  try {
    final cipher = pc.GCMBlockCipher(pc.AESEngine())
      ..init(
        false,
        pc.AEADParameters(pc.KeyParameter(encKey), 128, nonce, aad),
      );
    return cipher.process(Uint8List.fromList(data));
  } catch (_) {
    throw StateError('AEAD authentication tag mismatch');
  }
}

Uint8List cryptAttachmentChunk(
  List<int> data,
  List<int> key,
  int chunkIndex, {
  bool encrypt = true,
  int offset = 0,
  required String fileId,
  required int totalBytes,
}) {
  if (encrypt) {
    return encryptAttachmentChunk(
      data,
      key,
      chunkIndex,
      fileId: fileId,
      totalBytes: totalBytes,
      offset: offset,
    );
  }
  return decryptAttachmentChunk(
    data,
    key,
    chunkIndex,
    fileId: fileId,
    totalBytes: totalBytes,
    offset: offset,
  );
}
