import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/resumable_blob.dart';
import 'package:orbits_flutter/core/path_byte_stream.dart';
import 'package:orbits_flutter/core/path_byte_stream_stub.dart' as stub;

const _scope = 'path-scope';
const _fileId = 'path-file';

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

  test(
    'seal plaintext path to ciphertext file never holds the fileKey',
    () async {
      expect(
        await sealPlaintextPathToCipherFile(
          'https://evil.example/x',
          [1, 2, 3],
          scope: _scope,
          fileId: _fileId,
        ),
        isNull,
      );
      expect(
        await sealPlaintextPathToCipherFile(
          '/nope',
          const <int>[1],
          scope: _scope,
          fileId: _fileId,
        ),
        isNull,
      );

      final dir = Directory.systemTemp.createTempSync('orbits-aead-path-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final key = List<int>.generate(32, (i) => i + 1);
      final plain = List<int>.generate(70 * 1024, (i) => i % 251);
      final src = File('${dir.path}${Platform.pathSeparator}plain.bin')
        ..writeAsBytesSync(plain);
      final write = await sealPlaintextPathToCipherFile(
        src.path,
        key,
        scope: _scope,
        fileId: _fileId,
      );
      expect(write, isNotNull);
      addTearDown(write!.dispose);
      expect(write.plaintextBytes, plain.length);
      expect(write.chunkCount, 2);
      expect(write.path.contains('://'), isFalse);
      final cipher = File(write.path).readAsBytesSync();
      expect(cipher, isNot(equals(plain)));
      expect(write.firstCipher, cipher.sublist(0, write.firstCipher.length));
      final chunks = ResumableAttachment.chunk(
        plain,
        key,
        scope: _scope,
        fileId: _fileId,
      );
      expect(chunks, hasLength(2));
      expect(chunks.first.ciphertext, isNot(equals(write.firstCipher)));
      expect(
        ResumableAttachment.decrypt(
          chunks,
          key,
          scope: _scope,
          fileId: _fileId,
          totalBytes: plain.length,
        ),
        plain,
      );
      final roundTrip = await openCipherPathToPlaintext(
        write.path,
        key,
        scope: _scope,
        fileId: _fileId,
        totalBytes: plain.length,
      );
      expect(roundTrip, plain);
      expect(
        File('lib/core/path_byte_stream_io.dart').readAsStringSync(),
        isNot(contains('readAsBytes')),
      );
    },
  );

  test('web stub never opens a path', () async {
    expect(stub.localPathLength('/tmp/x'), isNull);
    expect(stub.openLocalPathByteStream('/tmp/x'), isNull);
    expect(
      await stub.sealPlaintextPathToCipherFile(
        '/tmp/x',
        [1],
        scope: _scope,
        fileId: _fileId,
      ),
      isNull,
    );
    expect(
      await stub.openCipherPathToPlaintext(
        '/tmp/x',
        [1],
        scope: _scope,
        fileId: _fileId,
      ),
      isNull,
    );
    expect(
      await stub.openCipherPathToPlaintextFile(
        '/tmp/x',
        [1],
        scope: _scope,
        fileId: _fileId,
      ),
      isNull,
    );
    expect(await stub.copyLocalPathToStableFile('/tmp/x', '/tmp/y'), isNull);
  });

  test(
    'open ciphertext path to plaintext file never holds the fileKey',
    () async {
      expect(
        await openCipherPathToPlaintextFile(
          'https://evil.example/x',
          [1, 2, 3],
          scope: _scope,
          fileId: _fileId,
        ),
        isNull,
      );
      expect(
        await openCipherPathToPlaintextFile(
          '/nope',
          const <int>[1],
          scope: _scope,
          fileId: _fileId,
        ),
        isNull,
      );

      final dir = Directory.systemTemp.createTempSync('orbits-aead-pt-file-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final key = List<int>.generate(32, (i) => i + 3);
      final plain = List<int>.generate(70 * 1024, (i) => i % 247);
      final src = File('${dir.path}${Platform.pathSeparator}plain.bin')
        ..writeAsBytesSync(plain);
      final write = await sealPlaintextPathToCipherFile(
        src.path,
        key,
        scope: _scope,
        fileId: _fileId,
      );
      expect(write, isNotNull);
      addTearDown(write!.dispose);
      final dest = await openCipherPathToPlaintextFile(
        write.path,
        key,
        scope: _scope,
        fileId: _fileId,
        totalBytes: plain.length,
      );
      expect(dest, isNotNull);
      expect(dest!.contains('://'), isFalse);
      addTearDown(() {
        try {
          File(dest).parent.deleteSync(recursive: true);
        } catch (_) {}
      });
      expect(File(dest).readAsBytesSync(), plain);
      expect(File(write.path).readAsBytesSync(), isNot(equals(plain)));
      expect(
        File('lib/core/path_byte_stream_io.dart').readAsStringSync(),
        isNot(contains('readAsBytes')),
      );
      expect(
        File('lib/core/path_byte_stream_io.dart').readAsStringSync(),
        contains('openCipherPathToPlaintextFile'),
      );
    },
  );

  test('copyLocalPathToStableFile streams without readAsBytes', () async {
    expect(
      await copyLocalPathToStableFile('https://evil.example/x', '/tmp'),
      isNull,
    );
    expect(await copyLocalPathToStableFile('/nope', '/tmp'), isNull);

    final dir = Directory.systemTemp.createTempSync('orbits-copy-src-');
    final destRoot = Directory.systemTemp.createTempSync('orbits-copy-dest-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      if (destRoot.existsSync()) destRoot.deleteSync(recursive: true);
    });
    final plain = List<int>.generate(70 * 1024, (i) => i % 199);
    final src = File('${dir.path}${Platform.pathSeparator}plain.bin')
      ..writeAsBytesSync(plain);
    expect(
      await copyLocalPathToStableFile(src.path, 'https://evil.example/x'),
      isNull,
    );
    final dest = await copyLocalPathToStableFile(src.path, destRoot.path);
    expect(dest, isNotNull);
    expect(dest!.contains('://'), isFalse);
    expect(File(dest).readAsBytesSync(), plain);
    expect(dest, isNot(src.path));
    expect(
      File('lib/core/path_byte_stream_io.dart').readAsStringSync(),
      isNot(contains('readAsBytes')),
    );
    expect(
      File('lib/core/attachment_store_io.dart').readAsStringSync(),
      contains('orbits-file-blobs'),
    );
    expect(
      File('lib/core/attachment_store_io.dart').readAsStringSync(),
      isNot(contains('http://')),
    );
    expect(
      File('lib/state/messaging_notifier.dart').readAsStringSync(),
      contains('persistLocalAttachmentPath'),
    );
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('persistLocalAttachmentPath'),
    );
  });
}
