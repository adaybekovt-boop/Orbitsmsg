// R12 — sender must not show complete until the receiver persists + ACKs.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/base64_helpers.dart';
import 'package:orbits_flutter/core/orbits_drop.dart';

Uint8List _bytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i * 17 + 1) & 0xff));

void main() {
  test('happy path: persist + ack marks outgoing complete', () async {
    final completed = <String>[];
    late DropEngine sender;
    late DropEngine receiver;
    sender = DropEngine(
      chunkSize: 64,
      onComplete: (id, dir) {
        if (dir == DropDirection.outgoing) completed.add(id);
      },
    );
    receiver = DropEngine(
      chunkSize: 64,
      persistIncoming: (_, __) async => true,
      onReply: (peer, pkt) =>
          unawaited(sender.handleInbound(pkt, peerId: 'bob')),
    );

    var inbound = Future<void>.value();
    await sender.sendFile(
      bytes: _bytes(20),
      name: 'ok.bin',
      mime: 'application/octet-stream',
      peerId: 'bob',
      ackTimeout: const Duration(seconds: 2),
      send: (p) {
        inbound = inbound.then((_) => receiver.handleInbound(p, peerId: 'alice'));
        return true;
      },
    );
    expect(completed, hasLength(1));
  });

  test('receiver persist failure never completes the sender', () async {
    final completed = <String>[];
    final failed = <String>[];
    late DropEngine sender;
    late DropEngine receiver;
    sender = DropEngine(
      chunkSize: 64,
      onComplete: (id, dir) {
        if (dir == DropDirection.outgoing) completed.add(id);
      },
      onFailed: (id, dir, _) {
        if (dir == DropDirection.outgoing) failed.add(id);
      },
    );
    receiver = DropEngine(
      chunkSize: 64,
      persistIncoming: (_, __) async => false,
      onReply: (peer, pkt) =>
          unawaited(sender.handleInbound(pkt, peerId: 'bob')),
    );

    var inbound = Future<void>.value();
    await expectLater(
      sender.sendFile(
        bytes: _bytes(20),
        name: 'fail.bin',
        mime: 'application/octet-stream',
        peerId: 'bob',
        ackTimeout: const Duration(seconds: 2),
        send: (p) {
          inbound = inbound.then((_) => receiver.handleInbound(p, peerId: 'alice'));
          return true;
        },
      ),
      throwsStateError,
    );
    expect(completed, isEmpty);
    expect(failed, isNotEmpty);
  });

  test('delayed handshake / no receiver: timeout is not complete', () async {
    final completed = <String>[];
    final sender = DropEngine(
      onComplete: (id, dir) {
        if (dir == DropDirection.outgoing) completed.add(id);
      },
    );
    await expectLater(
      sender.sendFile(
        bytes: _bytes(8),
        name: 'late.bin',
        mime: 'application/octet-stream',
        ackTimeout: const Duration(milliseconds: 80),
        send: (_) => true, // written, but nobody ACKs
      ),
      throwsStateError,
    );
    expect(completed, isEmpty);
  });

  test('channel close before ACK is not complete', () async {
    final completed = <String>[];
    final sender = DropEngine(
      onComplete: (id, dir) {
        if (dir == DropDirection.outgoing) completed.add(id);
      },
    );
    final sendFuture = sender.sendFile(
      bytes: _bytes(8),
      name: 'cut.bin',
      mime: 'application/octet-stream',
      peerId: 'bob',
      ackTimeout: const Duration(seconds: 2),
      send: (_) => true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    sender.resetPeer('bob');
    await expectLater(sendFuture, throwsStateError);
    expect(completed, isEmpty);
  });

  test('persist throw nacks and does not complete sender', () async {
    final completed = <String>[];
    late DropEngine sender;
    late DropEngine receiver;
    sender = DropEngine(
      onComplete: (id, dir) {
        if (dir == DropDirection.outgoing) completed.add(id);
      },
    );
    receiver = DropEngine(
      persistIncoming: (_, __) async => throw StateError('disk full'),
      onReply: (peer, pkt) =>
          unawaited(sender.handleInbound(pkt, peerId: 'bob')),
    );
    var inbound = Future<void>.value();
    await expectLater(
      sender.sendFile(
        bytes: _bytes(8),
        name: 'disk.bin',
        mime: 'application/octet-stream',
        ackTimeout: const Duration(seconds: 2),
        send: (p) {
          inbound = inbound.then((_) => receiver.handleInbound(p, peerId: 'alice'));
          return true;
        },
      ),
      throwsStateError,
    );
    expect(completed, isEmpty);
  });

  test('ACK from a different peer does not complete the sender (R6-09)',
      () async {
    final completed = <String>[];
    String? fileIdB64;
    final sender = DropEngine(
      onComplete: (id, dir) {
        if (dir == DropDirection.outgoing) completed.add(id);
      },
    );
    final sendFuture = sender.sendFile(
      bytes: _bytes(8),
      name: 'x.bin',
      mime: 'application/octet-stream',
      peerId: 'ORBIT-BOB',
      ackTimeout: const Duration(milliseconds: 250),
      send: (p) {
        if (p is Map && p['type'] == 'file-start') {
          fileIdB64 = p['fileId'] as String?;
        }
        return true;
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(fileIdB64, isNotNull);
    await sender.handleInbound(
      <String, Object?>{'type': 'file-ack', 'fileId': fileIdB64},
      peerId: 'ORBIT-MALLORY',
    );
    await expectLater(sendFuture, throwsStateError);
    expect(completed, isEmpty);
  });

  test('oversize file-start NACKs immediately (R6-10)', () async {
    final replies = <Object>[];
    final receiver = DropEngine(
      onReply: (_, pkt) => replies.add(pkt),
    );
    await receiver.handleInbound(
      <String, Object?>{
        'type': 'file-start',
        'fileId': bytesToBase64(Uint8List(16)),
        'name': 'huge.bin',
        'size': kMaxDropFileBytes + 1,
      },
      peerId: 'ORBIT-ALICE',
    );
    expect(replies, isNotEmpty);
    expect((replies.first as Map)['type'], 'file-nack');
  });

  test('resetPeer during waitForDrain aborts the rest of the send (R6-11)',
      () async {
    final sent = <Object>[];
    final drain = Completer<void>();
    final sender = DropEngine(chunkSize: 4);
    final future = sender.sendFile(
      bytes: _bytes(12),
      name: 'slow.bin',
      mime: 'application/octet-stream',
      peerId: 'ORBIT-BOB',
      ackTimeout: const Duration(milliseconds: 200),
      send: (p) {
        sent.add(p);
        return true;
      },
      waitForDrain: () => drain.future,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    sender.resetPeer('ORBIT-BOB');
    drain.complete();
    await expectLater(future, throwsStateError);
    final types = sent.whereType<Map>().map((m) => m['type']).toList();
    expect(types, isNot(contains('file-end')));
    expect(types, contains('file-abort'));
  });
}
