import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/resumable_blob.dart';

void main() {
  test('chunk, drop one piece, resume, then decrypt', () {
    final key = List<int>.generate(32, (i) => i + 1);
    final plain = List<int>.generate(70 * 1024, (i) => i % 251);
    final chunks = ResumableAttachment.chunk(
      plain,
      key,
      fileId: 'f1',
      totalBytes: plain.length,
    );
    expect(chunks, hasLength(2));
    final firstOnly = ResumableAttachment(
      fileId: 'f1',
      totalBytes: plain.length,
      fileKey: key,
      chunks: [chunks.first],
    );
    expect(firstOnly.isComplete, isFalse);
    final resumed = ResumableAttachment(
      fileId: 'f1',
      totalBytes: plain.length,
      fileKey: key,
      chunks: [...firstOnly.chunks, chunks.last],
    );
    expect(resumed.isComplete, isTrue);
    expect(
      ResumableAttachment.decrypt(
        resumed.chunks,
        key,
        fileId: 'f1',
        totalBytes: plain.length,
      ),
      plain,
    );
  });

  test('tampered chunk is rejected', () {
    final key = List<int>.filled(8, 3);
    final chunks = ResumableAttachment.chunk(
      List<int>.filled(16, 1),
      key,
      fileId: 'f1',
      totalBytes: 16,
    );
    final bad = AttachmentChunk(
      index: chunks.first.index,
      offset: chunks.first.offset,
      ciphertext: chunks.first.ciphertext,
      hash: 'deadbeef',
    );
    expect(
      () => ResumableAttachment.decrypt(
        [bad],
        key,
        fileId: 'f1',
        totalBytes: 16,
      ),
      throwsStateError,
    );
  });

  test('AEAD tag failure rejects modified ciphertext or altered offset', () {
    final key = List<int>.generate(32, (i) => i + 1);
    final plain = [10, 20, 30, 40, 50];
    final ct = encryptAttachmentChunk(
      plain,
      key,
      0,
      fileId: 'aad',
      totalBytes: plain.length,
      offset: 0,
    );

    // Decrypt succeeds with matching parameters
    final decrypted = decryptAttachmentChunk(
      ct,
      key,
      0,
      fileId: 'aad',
      totalBytes: plain.length,
      offset: 0,
    );
    expect(decrypted, plain);

    // Tampered offset (AAD mismatch) throws StateError
    expect(
      () => decryptAttachmentChunk(
        ct,
        key,
        0,
        fileId: 'aad',
        totalBytes: plain.length,
        offset: 100,
      ),
      throwsStateError,
    );

    // Tampered chunk index throws StateError
    expect(
      () => decryptAttachmentChunk(
        ct,
        key,
        1,
        fileId: 'aad',
        totalBytes: plain.length,
        offset: 0,
      ),
      throwsStateError,
    );

    // Tampered ciphertext bit throws StateError
    final corrupted = List<int>.from(ct);
    corrupted[0] ^= 0x01;
    expect(
      () => decryptAttachmentChunk(
        corrupted,
        key,
        0,
        fileId: 'aad',
        totalBytes: plain.length,
        offset: 0,
      ),
      throwsStateError,
    );
  });

  test('10 MiB attachment survives a dropped middle chunk', () {
    final key = List<int>.generate(32, (i) => i + 3);
    final plain = List<int>.generate(10 * 1024 * 1024, (i) => i % 251);
    final chunks = ResumableAttachment.chunk(
      plain,
      key,
      fileId: 'big',
      totalBytes: plain.length,
    );
    expect(chunks.length, greaterThan(100));
    final dropped = chunks.where((c) => c.index != 3).toList();
    expect(
      ResumableAttachment(
        fileId: 'big',
        totalBytes: plain.length,
        fileKey: key,
        chunks: dropped,
      ).isComplete,
      isFalse,
    );
    final resumed = ResumableAttachment(
      fileId: 'big',
      totalBytes: plain.length,
      fileKey: key,
      chunks: [...dropped, chunks[3]],
    );
    expect(resumed.isComplete, isTrue);
    expect(
      ResumableAttachment.decrypt(
        resumed.chunks,
        key,
        fileId: 'big',
        totalBytes: plain.length,
      ),
      plain,
    );
  });

  test('50 MiB attachment survives a dropped middle chunk', () {
    final key = List<int>.generate(32, (i) => i + 5);
    final plain = List<int>.generate(50 * 1024 * 1024, (i) => i % 251);
    final chunks = ResumableAttachment.chunk(
      plain,
      key,
      fileId: 'huge',
      totalBytes: plain.length,
    );
    expect(chunks.length, greaterThan(400));
    final dropped = chunks.where((c) => c.index != 7).toList();
    expect(
      ResumableAttachment(
        fileId: 'huge',
        totalBytes: plain.length,
        fileKey: key,
        chunks: dropped,
      ).isComplete,
      isFalse,
    );
    final resumed = ResumableAttachment(
      fileId: 'huge',
      totalBytes: plain.length,
      fileKey: key,
      chunks: [...dropped, chunks[7]],
    );
    expect(resumed.isComplete, isTrue);
    expect(
      ResumableAttachment.decrypt(
        resumed.chunks,
        key,
        fileId: 'huge',
        totalBytes: plain.length,
      ),
      plain,
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('wrong key, cross-file substitution, reorder, and truncation fail', () {
    final keyA = List<int>.generate(32, (i) => i + 1);
    final keyB = List<int>.generate(32, (i) => 32 - i);
    final plain = List<int>.generate(70 * 1024, (i) => i % 251);
    final a = ResumableAttachment.chunk(
      plain,
      keyA,
      fileId: 'file-a',
      totalBytes: plain.length,
    );
    final b = ResumableAttachment.chunk(
      plain,
      keyA,
      fileId: 'file-b',
      totalBytes: plain.length,
    );
    expect(
      () => ResumableAttachment.decrypt(
        a,
        keyB,
        fileId: 'file-a',
        totalBytes: plain.length,
      ),
      throwsStateError,
    );
    expect(
      () => ResumableAttachment.decrypt(
        a,
        keyA,
        fileId: 'file-b',
        totalBytes: plain.length,
      ),
      throwsStateError,
    );
    expect(a.first.ciphertext, isNot(equals(b.first.ciphertext)));
    expect(
      decryptAttachmentChunk(
        a.first.ciphertext,
        keyA,
        a.first.index,
        fileId: 'file-a',
        totalBytes: plain.length,
        offset: a.first.offset,
      ),
      isNotEmpty,
    );
    expect(
      () => decryptAttachmentChunk(
        b.first.ciphertext,
        keyA,
        a.first.index,
        fileId: 'file-a',
        totalBytes: plain.length,
        offset: a.first.offset,
      ),
      throwsStateError,
    );
    expect(
      () => ResumableAttachment.decrypt(
        [
          AttachmentChunk(
            index: 0,
            offset: 0,
            ciphertext: a.last.ciphertext,
            hash: a.last.hash,
          ),
        ],
        keyA,
        fileId: 'file-a',
        totalBytes: plain.length,
      ),
      throwsStateError,
    );
    expect(
      () => ResumableAttachment.decrypt(
        [a.first, a.first],
        keyA,
        fileId: 'file-a',
        totalBytes: plain.length,
      ),
      throwsStateError,
    );
    expect(
      () => ResumableAttachment.decrypt(
        [a.first],
        keyA,
        fileId: 'file-a',
        totalBytes: plain.length,
      ),
      throwsStateError,
    );
  });
}
