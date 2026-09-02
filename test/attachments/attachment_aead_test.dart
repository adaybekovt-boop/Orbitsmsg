import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/attachment_aead.dart';
import 'package:orbits_flutter/attachments/resumable_blob.dart';
import 'package:orbits_flutter/core/path_byte_stream.dart';

const _scope = 'ORBIT-AAAAAAAAAAAAAAAA\x1fORBIT-BBBBBBBBBBBBBBBB';
const _fileId = 'att-aead-1';

List<int> _key() => List<int>.generate(32, (i) => i + 1);

List<int> _plain(int n) => List<int>.generate(n, (i) => i % 251);

void main() {
  test('roundtrip bulk for 0/1/64KiB/64KiB+1/~1MiB', () {
    final key = _key();
    for (final n in <int>[0, 1, 64 * 1024, 64 * 1024 + 1, 1024 * 1024]) {
      final plain = _plain(n);
      final chunks = ResumableAttachment.chunk(
        plain,
        key,
        scope: _scope,
        fileId: _fileId,
      );
      expect(
        ResumableAttachment.decrypt(
          chunks,
          key,
          scope: _scope,
          fileId: _fileId,
          totalBytes: n,
        ),
        plain,
      );
    }
  });

  test('roundtrip stream for 0/1/64KiB/64KiB+1/~1MiB', () async {
    final key = _key();
    for (final n in <int>[0, 1, 64 * 1024, 64 * 1024 + 1, 1024 * 1024]) {
      final plain = _plain(n);
      final chunks = await ResumableAttachment.chunkFromByteStream(
        Stream<List<int>>.fromIterable(
          n == 0 ? const <List<int>>[] : <List<int>>[plain],
        ),
        key,
        scope: _scope,
        fileId: _fileId,
        totalBytes: n,
      );
      expect(
        ResumableAttachment.decrypt(
          chunks,
          key,
          scope: _scope,
          fileId: _fileId,
          totalBytes: n,
        ),
        plain,
      );
    }
  });

  test('roundtrip path for 0/1/64KiB/64KiB+1/~1MiB', () async {
    final key = _key();
    final dir = Directory.systemTemp.createTempSync('orbits-aead-path-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    for (final n in <int>[0, 1, 64 * 1024, 64 * 1024 + 1, 1024 * 1024]) {
      final plain = _plain(n);
      final src = File('${dir.path}${Platform.pathSeparator}p-$n.bin')
        ..writeAsBytesSync(plain);
      final write = await sealPlaintextPathToCipherFile(
        src.path,
        key,
        scope: _scope,
        fileId: _fileId,
      );
      expect(write, isNotNull);
      addTearDown(write!.dispose);
      expect(write.plaintextBytes, n);
      expect(write.chunkCount, n == 0 ? 1 : (n + 64 * 1024 - 1) ~/ (64 * 1024));
      final got = await openCipherPathToPlaintext(
        write.path,
        key,
        scope: _scope,
        fileId: _fileId,
        totalBytes: n,
      );
      expect(got, plain);
      final dest = await openCipherPathToPlaintextFile(
        write.path,
        key,
        scope: _scope,
        fileId: _fileId,
        totalBytes: n,
      );
      expect(dest, isNotNull);
      addTearDown(() {
        try {
          File(dest!).parent.deleteSync(recursive: true);
        } catch (_) {}
      });
      expect(File(dest!).readAsBytesSync(), plain);
    }
  });

  test('tamper ciphertext, tag, or nonce fails closed', () {
    final key = _key();
    final plain = _plain(64);
    final env = encryptChunk(
      plaintext: plain,
      fileKey: key,
      scope: _scope,
      fileId: _fileId,
      index: 0,
      offset: 0,
      totalBytes: plain.length,
    );
    void expectFail(Uint8List bad) {
      expect(
        () => decryptChunk(
          envelope: bad,
          fileKey: key,
          scope: _scope,
          fileId: _fileId,
          index: 0,
          offset: 0,
          totalBytes: plain.length,
        ),
        throwsA(isA<AttachmentAeadError>()),
      );
    }

    final flipCt = Uint8List.fromList(env);
    flipCt[1 + 24] ^= 0x01;
    expectFail(flipCt);
    final flipTag = Uint8List.fromList(env);
    flipTag[flipTag.length - 1] ^= 0x01;
    expectFail(flipTag);
    final flipNonce = Uint8List.fromList(env);
    flipNonce[1] ^= 0x01;
    expectFail(flipNonce);
  });

  test(
    'tampered path open returns null and leaves no orbits-att-pt-*',
    () async {
      final key = _key();
      final plain = _plain(80);
      final dir = Directory.systemTemp.createTempSync('orbits-aead-tamper-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
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
      final bytes = File(write.path).readAsBytesSync();
      bytes[bytes.length - 1] ^= 0x5a;
      File(write.path).writeAsBytesSync(bytes);
      final before = Directory.systemTemp
          .listSync()
          .where((e) => e.path.contains('orbits-att-pt-'))
          .map((e) => e.path)
          .toSet();
      expect(
        await openCipherPathToPlaintext(
          write.path,
          key,
          scope: _scope,
          fileId: _fileId,
          totalBytes: plain.length,
        ),
        isNull,
      );
      expect(
        await openCipherPathToPlaintextFile(
          write.path,
          key,
          scope: _scope,
          fileId: _fileId,
          totalBytes: plain.length,
        ),
        isNull,
      );
      final after = Directory.systemTemp
          .listSync()
          .where((e) => e.path.contains('orbits-att-pt-'))
          .map((e) => e.path)
          .toSet();
      expect(after.difference(before), isEmpty);
    },
  );

  test('wrong key fails', () {
    final chunks = ResumableAttachment.chunk(
      _plain(32),
      _key(),
      scope: _scope,
      fileId: _fileId,
    );
    expect(
      () => ResumableAttachment.decrypt(
        chunks,
        List<int>.generate(32, (i) => i + 9),
        scope: _scope,
        fileId: _fileId,
        totalBytes: 32,
      ),
      throwsA(isA<AttachmentAeadError>()),
    );
  });

  test('wrong AD fields fail', () {
    final key = _key();
    final plain = _plain(16);
    final env = encryptChunk(
      plaintext: plain,
      fileKey: key,
      scope: _scope,
      fileId: _fileId,
      index: 0,
      offset: 0,
      totalBytes: plain.length,
    );
    void expectFail({
      String? scope,
      String? fileId,
      int? index,
      int? offset,
      int? totalBytes,
    }) {
      expect(
        () => decryptChunk(
          envelope: env,
          fileKey: key,
          scope: scope ?? _scope,
          fileId: fileId ?? _fileId,
          index: index ?? 0,
          offset: offset ?? 0,
          totalBytes: totalBytes ?? plain.length,
        ),
        throwsA(isA<AttachmentAeadError>()),
      );
    }

    expectFail(scope: 'other-scope');
    expectFail(fileId: 'other-file');
    expectFail(index: 1);
    expectFail(offset: 8);
    expectFail(totalBytes: plain.length + 1);
  });

  test('unknown version byte fails', () {
    final key = _key();
    final env = encryptChunk(
      plaintext: _plain(8),
      fileKey: key,
      scope: _scope,
      fileId: _fileId,
      index: 0,
      offset: 0,
      totalBytes: 8,
    );
    env[0] = 99;
    expect(
      () => decryptChunk(
        envelope: env,
        fileKey: key,
        scope: _scope,
        fileId: _fileId,
        index: 0,
        offset: 0,
        totalBytes: 8,
      ),
      throwsA(isA<AttachmentAeadError>()),
    );
  });

  test('duplicate nonce is rejected', () {
    final key = _key();
    final chunk = ResumableAttachment.chunk(
      _plain(24),
      key,
      scope: _scope,
      fileId: _fileId,
    ).single;
    expect(
      () => ResumableAttachment.decrypt(
        [chunk, chunk],
        key,
        scope: _scope,
        fileId: _fileId,
        totalBytes: 24,
      ),
      throwsA(isA<AttachmentAeadError>()),
    );
  });

  test('retry encrypts the same chunk with a fresh nonce', () {
    final key = _key();
    final slice = _plain(40);
    final a = encryptChunk(
      plaintext: slice,
      fileKey: key,
      scope: _scope,
      fileId: _fileId,
      index: 0,
      offset: 0,
      totalBytes: slice.length,
    );
    final b = encryptChunk(
      plaintext: slice,
      fileKey: key,
      scope: _scope,
      fileId: _fileId,
      index: 0,
      offset: 0,
      totalBytes: slice.length,
    );
    expect(a, isNot(equals(b)));
    expect(a.sublist(1, 25), isNot(equals(b.sublist(1, 25))));
    expect(
      decryptChunk(
        envelope: a,
        fileKey: key,
        scope: _scope,
        fileId: _fileId,
        index: 0,
        offset: 0,
        totalBytes: slice.length,
      ),
      slice,
    );
    expect(
      decryptChunk(
        envelope: b,
        fileKey: key,
        scope: _scope,
        fileId: _fileId,
        index: 0,
        offset: 0,
        totalBytes: slice.length,
      ),
      slice,
    );
  });
}
