// DropEngine — chunked transfer + SHA-256 reassembly, end to end (sender's
// emitted packets replayed into a receiver). No WebRTC needed.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/base64_helpers.dart';
import 'package:orbits_flutter/core/orbits_drop.dart';

Uint8List _bytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i * 31 + 7) & 0xff));

/// Run a full transfer of [data] through a fresh sender→receiver pair.
/// Returns the received (meta, bytes) or null if it failed.
Future<({DropFileMeta meta, Uint8List bytes})?> _transfer(
  Uint8List data, {
  int chunkSize = dropChunkSize,
  void Function(List<Object> packets)? tamper,
}) async {
  final packets = <Object>[];
  final sender = DropEngine(chunkSize: chunkSize);
  await sender.sendFile(
    bytes: data,
    name: 'f.bin',
    mime: 'application/octet-stream',
    send: packets.add,
  );

  if (tamper != null) tamper(packets);

  ({DropFileMeta meta, Uint8List bytes})? got;
  String? failure;
  final receiver = DropEngine(
    chunkSize: chunkSize,
    onIncomingReady: (meta, bytes) => got = (meta: meta, bytes: bytes),
    onFailed: (_, __, reason) => failure = reason,
  );
  for (final p in packets) {
    await receiver.handleInbound(p);
  }
  if (failure != null) return null;
  return got;
}

void main() {
  group('DropEngine transfer', () {
    test('round-trips an empty file', () async {
      final r = await _transfer(Uint8List(0));
      expect(r, isNotNull);
      expect(r!.bytes, isEmpty);
      expect(r.meta.size, 0);
    });

    test('round-trips a sub-chunk file', () async {
      final data = _bytes(100);
      final r = await _transfer(data, chunkSize: 64);
      expect(r!.bytes, equals(data));
      expect(r.meta.totalChunks, 2);
    });

    test('round-trips a file on an exact chunk boundary', () async {
      final data = _bytes(128);
      final r = await _transfer(data, chunkSize: 64);
      expect(r!.bytes, equals(data));
      expect(r.meta.totalChunks, 2);
    });

    test('round-trips a multi-chunk file with a remainder', () async {
      final data = _bytes(64 * 5 + 13);
      final r = await _transfer(data, chunkSize: 64);
      expect(r!.bytes, equals(data));
      expect(r.bytes.length, data.length);
    });

    test('preserves metadata (name/mime/size/hash)', () async {
      final packets = <Object>[];
      final sender = DropEngine();
      await sender.sendFile(
        bytes: _bytes(10),
        name: 'photo.jpg',
        mime: 'image/jpeg',
        send: packets.add,
      );
      final start = packets.first as Map;
      expect(start['type'], 'file-start');
      expect(start['name'], 'photo.jpg');
      expect(start['mime'], 'image/jpeg');
      expect(start['size'], 10);
      expect((start['hash'] as String).length, 64); // sha-256 hex
    });

    test('survives duplicate chunks (dedup)', () async {
      final data = _bytes(64 * 3);
      final r = await _transfer(
        data,
        chunkSize: 64,
        tamper: (packets) {
          // Duplicate the first binary chunk right after itself.
          final idx = packets.indexWhere((p) => p is Uint8List);
          packets.insert(idx + 1, packets[idx]);
        },
      );
      expect(r!.bytes, equals(data));
    });

    test('fails the integrity check on a corrupted chunk', () async {
      final data = _bytes(64 * 3);
      final r = await _transfer(
        data,
        chunkSize: 64,
        tamper: (packets) {
          final idx = packets.indexWhere((p) => p is Uint8List);
          final frame = packets[idx] as Uint8List;
          frame[frame.length - 1] ^= 0xff; // flip a payload byte
        },
      );
      expect(r, isNull); // onFailed fired, no file delivered
    });
  });

  group('DropEngine abort', () {
    test('aborting mid-send stops the loop and emits drop-abort', () async {
      final packets = <Object>[];
      final sender = DropEngine(chunkSize: 64);
      const id = '00112233445566778899aabbccddeeff';
      var drains = 0;
      await expectLater(
        sender.sendFile(
          bytes: _bytes(64 * 10),
          name: 'big.bin',
          mime: 'application/octet-stream',
          send: packets.add,
          fileId: id,
          waitForDrain: () async {
            if (++drains == 2) sender.abortOutgoing(id);
          },
        ),
        throwsStateError,
      );
      expect(packets.any((p) => p is Map && p['type'] == 'file-abort'), isTrue);
      // Didn't send all 10 chunks.
      expect(packets.whereType<Uint8List>().length, lessThan(10));
    });
  });

  group('DropEngine inbound caps', () {
    test('rejects file-start above kMaxDropFileBytes', () async {
      String? failure;
      var started = false;
      final receiver = DropEngine(
        onIncomingStart: (_) => started = true,
        onFailed: (_, __, reason) => failure = reason,
      );
      final fileId = bytesToBase64(Uint8List(16));
      await receiver.handleInbound(<String, Object?>{
        'type': 'file-start',
        'fileId': fileId,
        'name': 'huge.bin',
        'size': kMaxDropFileBytes + 1,
      });
      expect(started, isFalse);
      expect(failure, isNotNull);
    });

    test('ignores oversized inbound frames', () async {
      final receiver = DropEngine();
      final frame = Uint8List(kMaxDropFrameBytes + 1);
      frame[0] = 1;
      expect(await receiver.handleInbound(frame), isFalse);
    });

    test('caps concurrent inbound transfers', () async {
      String? failure;
      final receiver = DropEngine(
        onFailed: (_, __, reason) => failure = reason,
      );
      for (var i = 0; i < kMaxDropIncoming; i++) {
        final id = Uint8List(16)..[0] = i + 1;
        await receiver.handleInbound(<String, Object?>{
          'type': 'file-start',
          'fileId': bytesToBase64(id),
          'name': 'f$i',
          'size': 10,
        });
      }
      expect(failure, isNull);
      await receiver.handleInbound(<String, Object?>{
        'type': 'file-start',
        'fileId': bytesToBase64(Uint8List(16)..[0] = 99),
        'name': 'overflow',
        'size': 10,
      });
      expect(failure, isNotNull);
    });
  });

  group('DropEngine progress', () {
    test('reports monotonic outgoing progress ending at total', () async {
      final data = _bytes(64 * 4);
      final sent = <int>[];
      final sender = DropEngine(
        chunkSize: 64,
        onProgress: (id, s, t, dir) {
          if (dir == DropDirection.outgoing) sent.add(s);
        },
      );
      await sender.sendFile(
        bytes: data,
        name: 'f',
        mime: 'application/octet-stream',
        send: (_) {},
      );
      expect(sent.last, data.length);
      for (var i = 1; i < sent.length; i++) {
        expect(sent[i], greaterThan(sent[i - 1]));
      }
    });
  });
}
