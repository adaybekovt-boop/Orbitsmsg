import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/resumable_blob.dart';

void main() {
  test('PeerJS stays 12 MiB; native path chat may use 50 MiB', () {
    expect(kMaxPeerJsFileRawBytes, 12 * 1024 * 1024);
    expect(kMaxNativeAttachBytes, 50 * 1024 * 1024);
  });

  test('chunk, drop one piece, resume, then decrypt', () {
    final key = List<int>.generate(32, (i) => i + 1);
    final plain = List<int>.generate(70 * 1024, (i) => i % 251);
    final chunks = ResumableAttachment.chunk(plain, key);
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
    expect(ResumableAttachment.decrypt(resumed.chunks, key), plain);
  });

  test('tampered chunk is rejected', () {
    final key = List<int>.filled(8, 3);
    final chunks = ResumableAttachment.chunk(List<int>.filled(16, 1), key);
    final bad = AttachmentChunk(
      index: chunks.first.index,
      offset: chunks.first.offset,
      ciphertext: chunks.first.ciphertext,
      hash: 'deadbeef',
    );
    expect(
      () => ResumableAttachment.decrypt([bad], key),
      throwsStateError,
    );
  });

  test('10 MiB attachment survives a dropped middle chunk', () {
    final key = List<int>.generate(32, (i) => i + 3);
    final plain = List<int>.generate(10 * 1024 * 1024, (i) => i % 251);
    final chunks = ResumableAttachment.chunk(plain, key);
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
    expect(ResumableAttachment.decrypt(resumed.chunks, key), plain);
  });

  test('50 MiB attachment survives a dropped middle chunk', () {
    final key = List<int>.generate(32, (i) => i + 5);
    final plain = List<int>.generate(50 * 1024 * 1024, (i) => i % 251);
    final chunks = ResumableAttachment.chunk(plain, key);
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
    expect(ResumableAttachment.decrypt(resumed.chunks, key), plain);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('chunkFromByteStream matches chunk() without a single plaintext buffer',
      () async {
    final key = List<int>.generate(32, (i) => i + 7);
    final plain = List<int>.generate(70 * 1024, (i) => i % 251);
    final pieces = <List<int>>[];
    for (var i = 0; i < plain.length; i += 8000) {
      final end = i + 8000 > plain.length ? plain.length : i + 8000;
      pieces.add(plain.sublist(i, end));
    }
    final streamed = await ResumableAttachment.chunkFromByteStream(
      Stream<List<int>>.fromIterable(pieces),
      key,
    );
    final bulk = ResumableAttachment.chunk(plain, key);
    expect(streamed.length, bulk.length);
    expect(ResumableAttachment.decrypt(streamed, key), plain);
  });

  test('chunkStream yields without collecting the caller list', () async {
    final key = List<int>.generate(32, (i) => i + 9);
    final plain = List<int>.generate(70 * 1024, (i) => i % 199);
    var yielded = 0;
    final out = <AttachmentChunk>[];
    await for (final chunk in ResumableAttachment.chunkStream(
      Stream<List<int>>.fromIterable(<List<int>>[plain]),
      key,
    )) {
      yielded++;
      out.add(chunk);
    }
    expect(yielded, 2);
    expect(ResumableAttachment.decrypt(out, key), plain);
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('chunkStream'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      isNot(contains('chunkFromByteStream(plaintext, fileKey)')),
    );
  });
}
