import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/attachment_transfer.dart';
import 'package:orbits_flutter/attachments/resumable_blob.dart';
import 'package:orbits_flutter/attachments/temp_attachment_io.dart';

void main() {
  Future<File> fixture(Directory dir, int bytes, int fill) async {
    final file = File('${dir.path}/in.bin');
    final raf = await file.open(mode: FileMode.write);
    try {
      const step = 1024 * 1024;
      var left = bytes;
      while (left > 0) {
        final n = left > step ? step : left;
        await raf.writeFrom(List<int>.filled(n, fill));
        left -= n;
      }
    } finally {
      await raf.close();
    }
    return file;
  }

  Future<void> provePathTransfer(int size, int fill) async {
    final dir = await Directory.systemTemp.createTemp('orbits-att-$size-');
    addTearDown(() async {
      try {
        if (dir.existsSync()) await dir.delete(recursive: true);
      } catch (_) {}
    });
    final src = await fixture(dir, size, fill);
    const key = <int>[1, 2, 3, 4];
    final transfer = AttachmentTransfer(
      fileId: 'f-$size',
      totalBytes: size,
      fileKey: key,
      sourcePath: src.path,
    );
    final chunks = await transfer.readChunksFromPathAsync();
    final cut = chunks.length ~/ 3;
    transfer.acceptAll(chunks.take(cut), verifyHash: false);
    expect(transfer.missingIndexes, isNotEmpty);
    transfer.acceptAll(chunks.skip(cut ~/ 2), verifyHash: false);
    final dest = File('${dir.path}/out-$size.bin');
    await transfer.writeAssembled(dest.path);
    expect(dest.existsSync(), isTrue, reason: 'result must exist at ${dest.path}');
    expect(dest.lengthSync(), size);
    final sent = AttachmentTransfer.sha256File(src.path);
    final got = AttachmentTransfer.sha256File(dest.path);
    expect(got, sent);
    transfer.cleanupPartial();
    expect(transfer.cleaned, isTrue);
    expect(transfer.received, isEmpty);
  }

  test('10 MiB path transfer resumes and matches SHA-256', () async {
    await provePathTransfer(10 * 1024 * 1024, 7);
  });

  test(
    '50 MiB path transfer resumes and matches SHA-256',
    () async {
      await provePathTransfer(50 * 1024 * 1024, 9);
    },
    // Measured 10 MiB encrypt+decrypt+SHA ≈ 7s on this host; 50 MiB is
    // the same AES-GCM path at 5× bytes, so 30s is below real work.
    timeout: const Timeout(Duration(seconds: 60)),
  );

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

  test('completeToPath writes dest, matches sha256, and drops temps', () async {
    final dir = await Directory.systemTemp.createTemp('orbits-att4-');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final src = await fixture(dir, 128 * 1024, 4);
    final dest = File('${dir.path}/done.bin');
    final transfer = AttachmentTransfer(
      fileId: 'done',
      totalBytes: 128 * 1024,
      fileKey: const [8, 7, 6],
      sourcePath: src.path,
    );
    final digest = await transfer.completeToPath(dest.path);
    expect(dest.existsSync(), isTrue);
    expect(digest, AttachmentTransfer.sha256File(src.path));
    expect(transfer.cleaned, isTrue);
    expect(transfer.received, isEmpty);
  });

  test('deleteTempAttachment removes file and empty orbits temp dir', () async {
    final desc = await writeTempAttachment(
      bytes: List<int>.filled(64, 3),
      name: 'gone.bin',
      mime: 'application/octet-stream',
    );
    expect(desc, isNotNull);
    final path = desc!.path;
    expect(File(path).existsSync(), isTrue);
    await deleteTempAttachment(path);
    expect(File(path).existsSync(), isFalse);
    expect(Directory(File(path).parent.path).existsSync(), isFalse);
  });
}
