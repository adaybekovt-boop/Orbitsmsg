import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/attachment_transfer.dart';
import 'package:orbits_flutter/attachments/resumable_blob.dart';

void main() {
  Future<File> fixture(Directory dir, int bytes, int fill) async {
    final file = File('${dir.path}/in.bin');
    await file.writeAsBytes(List<int>.filled(bytes, fill), flush: true);
    return file;
  }

  test('10 MiB and 50 MiB path transfers resume after interruption', () async {
    final dir = await Directory.systemTemp.createTemp('orbits-att-');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    for (final size in [10 * 1024 * 1024, 50 * 1024 * 1024]) {
      final src = await fixture(dir, size, size == 10 * 1024 * 1024 ? 7 : 9);
      const key = <int>[1, 2, 3, 4];
      final transfer = AttachmentTransfer(
        fileId: 'f-$size',
        totalBytes: size,
        fileKey: key,
        sourcePath: src.path,
      );
      final chunks = transfer.readChunksFromPath();
      final cut = chunks.length ~/ 3;
      transfer.acceptAll(chunks.take(cut));
      expect(transfer.missingIndexes, isNotEmpty);
      transfer.acceptAll(chunks.skip(cut ~/ 2)); // duplicates + resume
      expect(
        transfer.assemble(),
        List<int>.filled(size, size == 10 * 1024 * 1024 ? 7 : 9),
      );
    }
  });

  test(
    'duplicate, reordered, corrupt, expired, cancel, and low-disk paths',
    () async {
      final dir = await Directory.systemTemp.createTemp('orbits-att2-');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      final src = await fixture(dir, 3000, 3);
      const key = <int>[9];
      final transfer = AttachmentTransfer(
        fileId: 'f',
        totalBytes: 3000,
        fileKey: key,
        sourcePath: src.path,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
      );
      final chunks = [...transfer.readChunksFromPath()].reversed;
      transfer.acceptAll(chunks);
      transfer.acceptAll(chunks);
      expect(transfer.assemble().length, 3000);

      final bad = AttachmentChunk(
        index: 0,
        offset: 0,
        ciphertext: Uint8List.fromList(const [1]),
        hash: 'nope',
      );
      expect(() => transfer.acceptChunk(bad, maxOffset: 0), throwsStateError);

      final expired = AttachmentTransfer(
        fileId: 'e',
        totalBytes: 3000,
        fileKey: key,
        sourcePath: src.path,
        expiresAt: 1,
        nowMs: () => 2,
      );
      expect(
        () => expired.acceptChunk(chunks.first, maxOffset: 0),
        throwsStateError,
      );

      final cancel = AttachmentTransfer(
        fileId: 'c',
        totalBytes: 3000,
        fileKey: key,
        sourcePath: src.path,
      );
      cancel.cancel();
      expect(cancel.cleaned, isTrue);
      expect(() => cancel.assemble(), throwsStateError);

      expect(
        () => AttachmentTransfer(
          fileId: 'q',
          totalBytes: kAttachmentMaxObjectBytes + 1,
          fileKey: key,
          sourcePath: src.path,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'streaming reads from a path without buffering the whole file in the caller',
    () async {
      final dir = await Directory.systemTemp.createTemp('orbits-att3-');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      final src = await fixture(dir, 200000, 5);
      var count = 0;
      await for (final chunk in streamAttachmentPath(
        src.path,
        const [2],
        fileId: 'stream',
      )) {
        count += 1;
        expect(chunk.ciphertext, isNotEmpty);
      }
      expect(count, greaterThan(1));
    },
  );
}
