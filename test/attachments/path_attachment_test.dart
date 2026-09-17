import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/path_attachment.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';

void main() {
  test('writes chunks at offset and hashes without buffering the file', () async {
    final dir = await Directory.systemTemp.createTemp('orbits-path-att-');
    addTearDown(() => dir.delete(recursive: true));
    final plain = List<int>.generate(80 * 1024, (i) => i % 251);
    final digest = sha256.convert(plain).toString();
    final id = attachmentIdFromDigest(digest);

    final first = await IncomingPathAttachment.open(
      id: id,
      name: 'resume.bin',
      totalBytes: plain.length,
      sha256hex: digest,
      directory: dir,
    );
    await first.writeChunk(0, plain.sublist(0, kFileChunkSize));
    expect(first.isComplete, isFalse);
    expect(first.nextOffset, kFileChunkSize);
    await first.close();

    final second = await IncomingPathAttachment.open(
      id: id,
      name: 'resume.bin',
      totalBytes: plain.length,
      sha256hex: digest,
      directory: dir,
    );
    expect(second.nextOffset, kFileChunkSize);
    await second.writeChunk(kFileChunkSize, plain.sublist(kFileChunkSize));
    final done = await second.complete();
    expect(done, isNotNull);
    expect(done!.sha256hex, digest);
    expect(File(done.path).readAsBytesSync(), plain);
    expect(
      File('lib/attachments/path_attachment.dart').readAsStringSync(),
      isNot(contains('Uint8List.fromList(incoming.bytes)')),
    );
  });

  test('complete refuses a hash mismatch', () async {
    final dir = await Directory.systemTemp.createTemp('orbits-path-bad-');
    addTearDown(() => dir.delete(recursive: true));
    final incoming = await IncomingPathAttachment.open(
      id: 'abcdabcdabcdabcd',
      name: 'bad.bin',
      totalBytes: 4,
      sha256hex: 'deadbeef',
      directory: dir,
    );
    await incoming.writeChunk(0, const [1, 2, 3, 4]);
    await expectLater(incoming.complete(), throwsStateError);
  });
}
