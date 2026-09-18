// Versioned XChaCha20-Poly1305 AEAD for native chat attachments.
// Hypercore / journal / attach-chunk frames carry envelopes only —
// never plaintext or the per-file key.

import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../peer/helpers.dart';

const int kAttachmentAeadVersion = 1;
const int kAttachmentAeadNonceBytes = 24;
const int kAttachmentAeadTagBytes = 16;
const int kAttachmentAeadVersionBytes = 1;
const int kAttachmentAeadOverhead =
    kAttachmentAeadVersionBytes +
    kAttachmentAeadNonceBytes +
    kAttachmentAeadTagBytes;
const int kAttachmentFileKeyBytes = 32;
const int kMaxSeenAttachmentNonces = 2048;

final _aead = Xchacha20.poly1305Aead().toSync();

class AttachmentAeadError implements Exception {
  AttachmentAeadError(this.message);
  final String message;

  @override
  String toString() => 'AttachmentAeadError: $message';
}

/// Conversation scope: the two normalized peer ids, sorted and joined.
String attachmentConversationScope(String peerA, String peerB) {
  final a = normalizePeerId(peerA);
  final b = normalizePeerId(peerB);
  if (a.compareTo(b) <= 0) return '$a\x1f$b';
  return '$b\x1f$a';
}

List<int> generateAttachmentFileKey() {
  final rng = Random.secure();
  return List<int>.generate(kAttachmentFileKeyBytes, (_) => rng.nextInt(256));
}

Uint8List attachmentAssociatedData({
  required int version,
  required String scope,
  required String fileId,
  required int index,
  required int offset,
  required int totalBytes,
}) {
  if (index < 0 || offset < 0 || totalBytes < 0) {
    throw AttachmentAeadError('negative AD field');
  }
  final scopeBytes = utf8.encode(scope);
  final fileIdBytes = utf8.encode(fileId);
  final out = BytesBuilder(copy: false);
  out.addByte(version);
  _addU32(out, scopeBytes.length);
  out.add(scopeBytes);
  _addU32(out, fileIdBytes.length);
  out.add(fileIdBytes);
  _addU64(out, index);
  _addU64(out, offset);
  _addU64(out, totalBytes);
  return out.toBytes();
}

/// `version(1) || nonce(24) || ciphertext || tag(16)`.
Uint8List encryptChunk({
  required List<int> plaintext,
  required List<int> fileKey,
  required String scope,
  required String fileId,
  required int index,
  required int offset,
  required int totalBytes,
}) {
  _requireKey(fileKey);
  _refuseUrl(scope, fileId);
  final nonce = _randomBytes(kAttachmentAeadNonceBytes);
  final aad = attachmentAssociatedData(
    version: kAttachmentAeadVersion,
    scope: scope,
    fileId: fileId,
    index: index,
    offset: offset,
    totalBytes: totalBytes,
  );
  final box = _aead.encryptSync(
    plaintext,
    secretKey: SecretKeyData(fileKey),
    nonce: nonce,
    aad: aad,
  );
  final concat = box.concatenation();
  final envelope = Uint8List(kAttachmentAeadVersionBytes + concat.length);
  envelope[0] = kAttachmentAeadVersion;
  envelope.setAll(1, concat);
  return envelope;
}

/// Fail closed on wrong key, tampered bytes, wrong tag, wrong AD, or
/// unknown version.
Uint8List decryptChunk({
  required List<int> envelope,
  required List<int> fileKey,
  required String scope,
  required String fileId,
  required int index,
  required int offset,
  required int totalBytes,
}) {
  _requireKey(fileKey);
  _refuseUrl(scope, fileId);
  if (envelope.length < kAttachmentAeadOverhead) {
    throw AttachmentAeadError('truncated envelope');
  }
  if (envelope[0] != kAttachmentAeadVersion) {
    throw AttachmentAeadError('unknown version');
  }
  try {
    final box = SecretBox.fromConcatenation(
      envelope.sublist(1),
      nonceLength: kAttachmentAeadNonceBytes,
      macLength: kAttachmentAeadTagBytes,
    );
    final pt = _aead.decryptSync(
      box,
      secretKey: SecretKeyData(fileKey),
      aad: attachmentAssociatedData(
        version: kAttachmentAeadVersion,
        scope: scope,
        fileId: fileId,
        index: index,
        offset: offset,
        totalBytes: totalBytes,
      ),
    );
    return Uint8List.fromList(pt);
  } on AttachmentAeadError {
    rethrow;
  } catch (_) {
    throw AttachmentAeadError('decrypt failed');
  }
}

Uint8List? attachmentEnvelopeNonce(List<int> envelope) {
  if (envelope.length < kAttachmentAeadOverhead) return null;
  if (envelope[0] != kAttachmentAeadVersion) return null;
  return Uint8List.fromList(envelope.sublist(1, 1 + kAttachmentAeadNonceBytes));
}

int attachmentPlaintextLengthOfEnvelope(int envelopeLength) {
  if (envelopeLength < kAttachmentAeadOverhead) return 0;
  return envelopeLength - kAttachmentAeadOverhead;
}

/// Infer plaintext length from a concatenated envelope file.
int? inferAttachmentPlaintextBytes(int cipherSize) {
  if (cipherSize == kAttachmentAeadOverhead) return 0;
  if (cipherSize < kAttachmentAeadOverhead) return null;
  final maxN = cipherSize ~/ kAttachmentAeadOverhead;
  for (var n = 1; n <= maxN; n++) {
    final total = cipherSize - n * kAttachmentAeadOverhead;
    if (total < 0) continue;
    final expectedN = total == 0 ? 1 : (total + 64 * 1024 - 1) ~/ (64 * 1024);
    if (expectedN == n) return total;
  }
  return null;
}

int attachmentCipherCapBytes({required int plaintextCap}) {
  if (plaintextCap < 0) return 0;
  final n = plaintextCap == 0
      ? 1
      : (plaintextCap + 64 * 1024 - 1) ~/ (64 * 1024);
  return plaintextCap + n * kAttachmentAeadOverhead;
}

/// Bounded per-[fileId] nonce set. Rejects a replayed nonce.
class AttachmentNonceTracker {
  AttachmentNonceTracker({this.maxEntries = kMaxSeenAttachmentNonces});

  final int maxEntries;
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();

  bool remember(List<int> nonce) {
    if (nonce.length != kAttachmentAeadNonceBytes) return false;
    final id = base64Encode(nonce);
    if (_seen.contains(id)) return false;
    if (_seen.length >= maxEntries) {
      _seen.remove(_seen.first);
    }
    _seen.add(id);
    return true;
  }
}

void _requireKey(List<int> fileKey) {
  if (fileKey.length != kAttachmentFileKeyBytes) {
    throw AttachmentAeadError('invalid file key');
  }
}

void _refuseUrl(String scope, String fileId) {
  if (scope.contains('://') || fileId.contains('://')) {
    throw AttachmentAeadError('refused scope or fileId');
  }
}

Uint8List _randomBytes(int n) {
  final rng = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => rng.nextInt(256)));
}

void _addU32(BytesBuilder out, int value) {
  final buf = ByteData(4)..setUint32(0, value);
  out.add(buf.buffer.asUint8List());
}

void _addU64(BytesBuilder out, int value) {
  final buf = ByteData(8)..setUint64(0, value);
  out.add(buf.buffer.asUint8List());
}
