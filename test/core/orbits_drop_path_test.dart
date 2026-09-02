import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/path_drop_store.dart';
import 'package:orbits_flutter/core/orbits_drop.dart';

Uint8List _bytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i * 31 + 7) & 0xff));

void main() {
  test('sendFileRanged plus path store never assemble the file in RAM', () async {
    final dir = await Directory.systemTemp.createTemp('orbits-drop-path-');
    addTearDown(() => dir.delete(recursive: true));
    final data = _bytes(64 * 5 + 13);
    final src = File('${dir.path}/src.bin')..writeAsBytesSync(data);
    final digest = sha256.convert(data).toString();
    String? readyPath;

    late DropEngine sender;
    late DropEngine receiver;
    sender = DropEngine(chunkSize: 64);
    receiver = DropEngine(
      chunkSize: 64,
      openIncomingStore: (meta, _) => PathDropChunkStore.open(
        meta: meta,
        directory: dir,
        chunkSize: 64,
      ),
      persistIncomingPath: (meta, path) async {
        readyPath = path;
        return true;
      },
      onIncomingReady: (meta, bytes) =>
          fail('path store must not assemble bytes'),
      onReply: (peer, pkt) =>
          unawaited(sender.handleInbound(pkt, peerId: peer)),
    );

    var inbound = Future<void>.value();
    final raf = await src.open();
    try {
      await sender.sendFileRanged(
        size: data.length,
        name: 'p.bin',
        mime: 'application/octet-stream',
        hash: digest,
        ackTimeout: const Duration(seconds: 2),
        read: (offset, length) async {
          await raf.setPosition(offset);
          final buf = Uint8List(length);
          final n = await raf.readInto(buf);
          return n == length ? buf : Uint8List.sublistView(buf, 0, n);
        },
        send: (p) {
          inbound =
              inbound.then((_) => receiver.handleInbound(p, peerId: 'alice'));
          return true;
        },
      );
    } finally {
      await raf.close();
    }
    await inbound;

    expect(readyPath, isNotNull);
    expect(File(readyPath!).readAsBytesSync(), data);
    expect(receiver.incomingBufferedBytes, 0);
  });

  test('file-resume continues from the contiguous prefix after loss', () async {
    final dir = await Directory.systemTemp.createTemp('orbits-drop-resume-');
    addTearDown(() => dir.delete(recursive: true));
    final data = _bytes(64 * 4);
    final digest = sha256.convert(data).toString();
    final fileId = dropNewFileId();

    final prefix = await PathDropChunkStore.open(
      meta: DropFileMeta(
        fileId: fileId,
        name: 'r.bin',
        size: data.length,
        mime: 'application/octet-stream',
        hash: digest,
        totalChunks: 4,
      ),
      directory: dir,
      chunkSize: 64,
    );
    await prefix.put(0, data.sublist(0, 64));
    await prefix.dispose();

    var binaryChunks = 0;
    String? donePath;
    late DropEngine sender;
    late DropEngine receiver;
    sender = DropEngine(chunkSize: 64);
    receiver = DropEngine(
      chunkSize: 64,
      openIncomingStore: (meta, _) => PathDropChunkStore.open(
        meta: meta,
        directory: dir,
        chunkSize: 64,
      ),
      persistIncomingPath: (_, path) async {
        donePath = path;
        return true;
      },
      onReply: (peer, pkt) =>
          unawaited(sender.handleInbound(pkt, peerId: peer)),
    );

    var inbound = Future<void>.value();
    await sender.sendFileRanged(
      size: data.length,
      name: 'r.bin',
      mime: 'application/octet-stream',
      hash: digest,
      fileId: fileId,
      ackTimeout: const Duration(seconds: 2),
      resumeWait: const Duration(seconds: 2),
      read: (offset, length) async =>
          Uint8List.sublistView(data, offset, offset + length),
      send: (p) {
        if (p is Uint8List) binaryChunks++;
        inbound =
            inbound.then((_) => receiver.handleInbound(p, peerId: 'alice'));
        return true;
      },
    );
    await inbound;

    expect(binaryChunks, 3, reason: 'prefix chunk must not be resent');
    expect(donePath, isNotNull);
    expect(File(donePath!).readAsBytesSync(), data);
  });
}
