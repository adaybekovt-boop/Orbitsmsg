// R02 — Drop inbound must bound memory by *received* bytes, not the
// declared size, key transfers by (peerId, fileId), and reject a
// stranger who only knows the fileId.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/base64_helpers.dart';
import 'package:orbits_flutter/core/orbits_drop.dart';

Uint8List _idBytes(int seed) => Uint8List.fromList(List<int>.filled(16, seed));

Uint8List _chunk(Uint8List idBytes, int seq, List<int> payload) {
  final frame = Uint8List(1 + 16 + 4 + payload.length);
  frame[0] = 1;
  frame.setRange(1, 17, idBytes);
  ByteData.sublistView(frame, 17, 21).setUint32(0, seq, Endian.big);
  frame.setRange(21, frame.length, payload);
  return frame;
}

void main() {
  group('R02 Drop inbound limits', () {
    test('declared size=1 but many unique chunks stays bounded and aborts',
        () async {
      String? failure;
      final receiver = DropEngine(
        chunkSize: 64,
        onFailed: (_, __, reason) => failure = reason,
      );
      final id = _idBytes(7);
      await receiver.handleInbound(
        <String, Object?>{
          'type': 'file-start',
          'fileId': bytesToBase64(id),
          'name': 'tiny.bin',
          'size': 1,
          'totalChunks': 1,
        },
        peerId: 'ORBIT-ALICE',
      );
      expect(receiver.incomingTransferCount, 1);

      for (var seq = 0; seq < 40; seq++) {
        await receiver.handleInbound(
          _chunk(id, seq, List<int>.filled(64, seq & 0xff)),
          peerId: 'ORBIT-ALICE',
        );
      }

      expect(receiver.incomingBufferedBytes, lessThanOrEqualTo(1),
          reason: 'chunks past declared size must not be copied');
      expect(failure, isNotNull);
      expect(receiver.incomingTransferCount, 0);
    });

    test('same fileId from a different peer cannot join the transfer',
        () async {
      ({DropFileMeta meta, Uint8List bytes})? ready;
      String? failure;
      final receiver = DropEngine(
        chunkSize: 64,
        onIncomingReady: (meta, bytes) => ready = (meta: meta, bytes: bytes),
        onFailed: (_, __, reason) => failure = reason,
      );
      final id = _idBytes(9);
      final payload = List<int>.filled(8, 0xab);
      await receiver.handleInbound(
        <String, Object?>{
          'type': 'file-start',
          'fileId': bytesToBase64(id),
          'name': 'a.bin',
          'size': 8,
          'hash': '',
          'totalChunks': 1,
        },
        peerId: 'ORBIT-ALICE',
      );

      // Attacker knows fileId but is a different peer.
      await receiver.handleInbound(
        _chunk(id, 0, List<int>.filled(8, 0xff)),
        peerId: 'ORBIT-MALLORY',
      );
      expect(receiver.incomingBufferedBytes, 0,
          reason: 'wrong peer must not land bytes in Alice\'s transfer');

      await receiver.handleInbound(
        _chunk(id, 0, payload),
        peerId: 'ORBIT-ALICE',
      );
      await receiver.handleInbound(
        <String, Object?>{'type': 'file-end', 'fileId': bytesToBase64(id)},
        peerId: 'ORBIT-ALICE',
      );

      expect(ready, isNotNull);
      expect(ready!.bytes, payload);
      expect(failure, isNull);
    });

    test('incomplete transfer expires after TTL', () async {
      var now = DateTime.utc(2026, 1, 1);
      String? failure;
      final receiver = DropEngine(
        transferTtl: const Duration(seconds: 30),
        clock: () => now,
        onFailed: (_, __, reason) => failure = reason,
      );
      final id = _idBytes(3);
      await receiver.handleInbound(
        <String, Object?>{
          'type': 'file-start',
          'fileId': bytesToBase64(id),
          'name': 'slow.bin',
          'size': 8,
          'totalChunks': 1,
        },
        peerId: 'ORBIT-ALICE',
      );
      expect(receiver.incomingTransferCount, 1);
      now = now.add(const Duration(seconds: 31));
      await receiver.handleInbound(
        <String, Object?>{'type': 'file-abort', 'fileId': 'not-used'},
        peerId: 'ORBIT-OTHER',
      );
      expect(receiver.incomingTransferCount, 0);
      expect(failure, contains('истекла'));
    });

    test('resetPeer drops only that sender\'s transfers', () async {
      final receiver = DropEngine();
      await receiver.handleInbound(
        <String, Object?>{
          'type': 'file-start',
          'fileId': bytesToBase64(_idBytes(1)),
          'name': 'a',
          'size': 4,
        },
        peerId: 'ORBIT-A',
      );
      await receiver.handleInbound(
        <String, Object?>{
          'type': 'file-start',
          'fileId': bytesToBase64(_idBytes(2)),
          'name': 'b',
          'size': 4,
        },
        peerId: 'ORBIT-B',
      );
      expect(receiver.incomingTransferCount, 2);
      receiver.resetPeer('ORBIT-A');
      expect(receiver.incomingTransferCount, 1);
    });
  });
}
