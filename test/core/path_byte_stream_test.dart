import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/resumable_blob.dart';
import 'package:orbits_flutter/core/path_byte_stream.dart';
import 'package:orbits_flutter/core/path_byte_stream_stub.dart' as stub;

void main() {
  test('native path stream refuses URLs and yields file bytes', () async {
    expect(localPathLength('https://evil.example/x'), isNull);
    expect(openLocalPathByteStream('https://evil.example/x'), isNull);
    expect(localPathLength('file://tmp/x'), isNull);
    expect(openLocalPathByteStream(''), isNull);

    final dir = Directory.systemTemp.createTempSync('orbits-path-stream-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final file = File('${dir.path}${Platform.pathSeparator}blob.bin')
      ..writeAsBytesSync(const <int>[7, 8, 9]);
    expect(localPathLength(file.path), 3);
    final stream = openLocalPathByteStream(file.path);
    expect(stream, isNotNull);
    final collected = <int>[];
    await for (final piece in stream!) {
      collected.addAll(piece);
    }
    expect(collected, const <int>[7, 8, 9]);
  });

  test('xor plaintext path to ciphertext file never holds the fileKey', () async {
    expect(
      await xorPlaintextPathToCipherFile('https://evil.example/x', [1, 2, 3]),
      isNull,
    );
    expect(await xorPlaintextPathToCipherFile('/nope', const <int>[1]), isNull);

    final dir = Directory.systemTemp.createTempSync('orbits-xor-path-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final key = List<int>.generate(32, (i) => i + 1);
    final plain = List<int>.generate(70 * 1024, (i) => i % 251);
    final src = File('${dir.path}${Platform.pathSeparator}plain.bin')
      ..writeAsBytesSync(plain);
    final write = await xorPlaintextPathToCipherFile(src.path, key);
    expect(write, isNotNull);
    addTearDown(write!.dispose);
    expect(write.sizeBytes, plain.length);
    expect(write.chunkCount, 2);
    expect(write.path.contains('://'), isFalse);
    final cipher = File(write.path).readAsBytesSync();
    expect(cipher, isNot(equals(plain)));
    expect(write.firstCipher, cipher.sublist(0, kAttachmentChunkSize));
    final chunks = ResumableAttachment.chunk(plain, key);
    expect(chunks, hasLength(2));
    expect(chunks.first.ciphertext, write.firstCipher);
    expect(
      File(write.path).readAsBytesSync().sublist(kAttachmentChunkSize),
      chunks.last.ciphertext,
    );
    expect(ResumableAttachment.decrypt(chunks, key), plain);
    expect(
      File('lib/core/path_byte_stream_io.dart').readAsStringSync(),
      isNot(contains('readAsBytes')),
    );
  });

  test('web stub never opens a path', () async {
    expect(stub.localPathLength('/tmp/x'), isNull);
    expect(stub.openLocalPathByteStream('/tmp/x'), isNull);
    expect(await stub.xorPlaintextPathToCipherFile('/tmp/x', [1]), isNull);
  });
}
