// Content-addressed chunked attachment. Per-file key wraps bytes with
// versioned XChaCha20-Poly1305; the mailbox/journal only store ciphertext
// + hashes.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'attachment_aead.dart';

export 'attachment_aead.dart'
    show
        AttachmentAeadError,
        attachmentConversationScope,
        generateAttachmentFileKey,
        kAttachmentAeadOverhead,
        kAttachmentAeadVersion;

const int kAttachmentChunkSize = 64 * 1024;

/// PeerJS base64 chat/room cap (JS UI gate). Native path-streamed
/// chat uses [kMaxNativeAttachBytes] instead.
const int kMaxPeerJsFileRawBytes = 12 * 1024 * 1024;

/// Native `attach-chunk` / path-streamed chat. Matches DualStackBridge
/// inbound cipher cap. Not the PeerJS live path.
const int kMaxNativeAttachBytes = 50 * 1024 * 1024;

const int kNativeAttachFileKeyBytes = kAttachmentFileKeyBytes;

/// File key from a local pending attachment map (Drift outbox). Null if
/// missing or not 32 bytes. Hypercore / mailbox must still not store this.
List<int>? nativeAttachFileKeyFromPayload(Map<String, Object?>? attachment) {
  if (attachment == null) return null;
  final b64 = attachment['fileKeyB64'];
  if (b64 is! String || b64.isEmpty) return null;
  if (b64.contains('://')) return null;
  try {
    final key = base64.decode(b64);
    if (key.length != kNativeAttachFileKeyBytes) return null;
    return key;
  } catch (_) {
    return null;
  }
}

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
    if (totalBytes == 0) {
      return chunks.length == 1 && chunks.first.index == 0;
    }
    if (chunks.isEmpty) return false;
    final expected =
        (totalBytes + kAttachmentChunkSize - 1) ~/ kAttachmentChunkSize;
    return receivedIndexes.length == expected;
  }

  static List<AttachmentChunk> chunk(
    List<int> plaintext,
    List<int> fileKey, {
    required String scope,
    required String fileId,
  }) {
    final totalBytes = plaintext.length;
    if (totalBytes == 0) {
      return [
        _oneChunk(
          0,
          const <int>[],
          fileKey,
          scope: scope,
          fileId: fileId,
          totalBytes: 0,
        ),
      ];
    }
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
      out.add(
        _oneChunk(
          offset,
          slice,
          fileKey,
          scope: scope,
          fileId: fileId,
          totalBytes: totalBytes,
        ),
      );
    }
    return out;
  }

  /// Stream plaintext from disk (or any source) without requiring a single
  /// in-memory `Uint8List` of the whole file.
  static Future<List<AttachmentChunk>> chunkFromByteStream(
    Stream<List<int>> incoming,
    List<int> fileKey, {
    required String scope,
    required String fileId,
    required int totalBytes,
  }) => chunkStream(
    incoming,
    fileKey,
    scope: scope,
    fileId: fileId,
    totalBytes: totalBytes,
  ).toList();

  /// Yield ciphertext chunks as plaintext arrives. Callers that send
  /// immediately must not collect the whole list. [totalBytes] is required
  /// for AEAD associated data.
  static Stream<AttachmentChunk> chunkStream(
    Stream<List<int>> incoming,
    List<int> fileKey, {
    required String scope,
    required String fileId,
    required int totalBytes,
  }) async* {
    if (totalBytes < 0) {
      throw AttachmentAeadError('invalid totalBytes');
    }
    if (totalBytes == 0) {
      yield _oneChunk(
        0,
        const <int>[],
        fileKey,
        scope: scope,
        fileId: fileId,
        totalBytes: 0,
      );
      return;
    }
    final pending = BytesBuilder(copy: false);
    var offset = 0;
    await for (final piece in incoming) {
      pending.add(piece);
      while (pending.length >= kAttachmentChunkSize &&
          offset + kAttachmentChunkSize <= totalBytes) {
        final buf = pending.takeBytes();
        final slice = buf.sublist(0, kAttachmentChunkSize);
        pending.add(buf.sublist(kAttachmentChunkSize));
        yield _oneChunk(
          offset,
          slice,
          fileKey,
          scope: scope,
          fileId: fileId,
          totalBytes: totalBytes,
        );
        offset += slice.length;
      }
    }
    final tail = pending.takeBytes();
    if (offset < totalBytes && tail.isNotEmpty) {
      yield _oneChunk(
        offset,
        tail,
        fileKey,
        scope: scope,
        fileId: fileId,
        totalBytes: totalBytes,
      );
    }
  }

  static AttachmentChunk _oneChunk(
    int offset,
    List<int> slice,
    List<int> fileKey, {
    required String scope,
    required String fileId,
    required int totalBytes,
  }) {
    final envelope = encryptChunk(
      plaintext: slice,
      fileKey: fileKey,
      scope: scope,
      fileId: fileId,
      index: offset ~/ kAttachmentChunkSize,
      offset: offset,
      totalBytes: totalBytes,
    );
    return AttachmentChunk(
      index: offset ~/ kAttachmentChunkSize,
      offset: offset,
      ciphertext: envelope,
      hash: sha256.convert(envelope).toString(),
    );
  }

  static Uint8List decrypt(
    List<AttachmentChunk> chunks,
    List<int> fileKey, {
    required String scope,
    required String fileId,
    required int totalBytes,
  }) {
    final ordered = [...chunks]..sort((a, b) => a.index.compareTo(b.index));
    final out = BytesBuilder(copy: false);
    final nonces = AttachmentNonceTracker();
    for (final chunk in ordered) {
      final actual = sha256.convert(chunk.ciphertext).toString();
      if (actual != chunk.hash) {
        throw AttachmentAeadError('attachment hash mismatch');
      }
      final nonce = attachmentEnvelopeNonce(chunk.ciphertext);
      if (nonce == null || !nonces.remember(nonce)) {
        throw AttachmentAeadError('replayed nonce');
      }
      out.add(
        decryptChunk(
          envelope: chunk.ciphertext,
          fileKey: fileKey,
          scope: scope,
          fileId: fileId,
          index: chunk.index,
          offset: chunk.offset,
          totalBytes: totalBytes,
        ),
      );
    }
    final plain = out.toBytes();
    if (plain.length != totalBytes) {
      throw AttachmentAeadError('plaintext length mismatch');
    }
    return plain;
  }
}
