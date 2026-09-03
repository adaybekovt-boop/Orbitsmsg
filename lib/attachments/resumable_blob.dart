// Content-addressed chunked attachment. Per-file key wraps bytes;
// the mailbox/journal only store ciphertext + hashes.

import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:pointycastle/export.dart' as pc;

const int kAttachmentChunkSize = 64 * 1024;
const int kAttachmentTagSize = 32;

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
      final ct = encryptAttachmentChunk(slice, fileKey, index, offset: offset);
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
      out.add(decryptAttachmentChunk(
        chunk.ciphertext,
        fileKey,
        chunk.index,
        offset: chunk.offset,
      ));
    }
    return out.toBytes();
  }
}

/// Authenticated encryption with associated data (AEAD) for attachment chunks.
/// Uses standard Encrypt-then-MAC (AES-256-CTR + HMAC-SHA256) with domain-separated
/// keys, 16-byte deterministic per-chunk IV, and 16-byte associated authenticated data
/// binding the chunk index and byte offset.
Uint8List encryptAttachmentChunk(
  List<int> data,
  List<int> key,
  int chunkIndex, {
  int offset = 0,
}) {
  if (key.isEmpty) {
    throw ArgumentError('file key required');
  }
  final encKey = Uint8List.fromList(
    sha256.convert(<int>[0x45, 0x4e, 0x43, 0x31, ...key]).bytes,
  );
  final macKey = Uint8List.fromList(
    sha256.convert(<int>[0x4d, 0x41, 0x43, 0x31, ...key]).bytes,
  );

  final ivData = Uint8List(16);
  final bd = ByteData.sublistView(ivData);
  bd.setUint32(0, 0x4f424154); // 'OBAT'
  bd.setUint64(8, chunkIndex);
  final iv = Uint8List.fromList(sha256.convert(ivData).bytes.sublist(0, 16));

  final cipher = pc.SICStreamCipher(pc.AESEngine())
    ..init(true, pc.ParametersWithIV(pc.KeyParameter(encKey), iv));
  final ciphertext = cipher.process(Uint8List.fromList(data));

  final aad = Uint8List(16);
  final abd = ByteData.sublistView(aad);
  abd.setUint64(0, chunkIndex);
  abd.setUint64(8, offset);

  final hmac = Hmac(sha256, macKey);
  final tag = hmac.convert(<int>[...aad, ...iv, ...ciphertext]).bytes;

  final out = BytesBuilder(copy: false);
  out.add(ciphertext);
  out.add(tag);
  return out.toBytes();
}

/// Authenticated decryption for attachment chunks with AEAD tag validation.
Uint8List decryptAttachmentChunk(
  List<int> data,
  List<int> key,
  int chunkIndex, {
  int offset = 0,
}) {
  if (key.isEmpty) {
    throw ArgumentError('file key required');
  }
  if (data.length < kAttachmentTagSize) {
    throw StateError('attachment chunk too short for AEAD tag');
  }
  final encKey = Uint8List.fromList(
    sha256.convert(<int>[0x45, 0x4e, 0x43, 0x31, ...key]).bytes,
  );
  final macKey = Uint8List.fromList(
    sha256.convert(<int>[0x4d, 0x41, 0x43, 0x31, ...key]).bytes,
  );

  final ciphertext = data.sublist(0, data.length - kAttachmentTagSize);
  final receivedTag = data.sublist(data.length - kAttachmentTagSize);

  final ivData = Uint8List(16);
  final bd = ByteData.sublistView(ivData);
  bd.setUint32(0, 0x4f424154); // 'OBAT'
  bd.setUint64(8, chunkIndex);
  final iv = Uint8List.fromList(sha256.convert(ivData).bytes.sublist(0, 16));

  final aad = Uint8List(16);
  final abd = ByteData.sublistView(aad);
  abd.setUint64(0, chunkIndex);
  abd.setUint64(8, offset);

  final hmac = Hmac(sha256, macKey);
  final expectedTag = hmac.convert(<int>[...aad, ...iv, ...ciphertext]).bytes;

  var diff = 0;
  for (var i = 0; i < kAttachmentTagSize; i++) {
    diff |= receivedTag[i] ^ expectedTag[i];
  }
  if (diff != 0) {
    throw StateError('AEAD authentication tag mismatch');
  }

  final cipher = pc.SICStreamCipher(pc.AESEngine())
    ..init(false, pc.ParametersWithIV(pc.KeyParameter(encKey), iv));
  return cipher.process(Uint8List.fromList(ciphertext));
}

Uint8List cryptAttachmentChunk(
  List<int> data,
  List<int> key,
  int chunkIndex, {
  bool encrypt = true,
  int offset = 0,
}) {
  if (encrypt) {
    return encryptAttachmentChunk(data, key, chunkIndex, offset: offset);
  } else {
    return decryptAttachmentChunk(data, key, chunkIndex, offset: offset);
  }
}
