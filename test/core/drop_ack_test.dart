// R12 — sender must not show complete until the receiver persists + ACKs.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
      onReply: (peer, pkt) => unawaited(sender.handleInbound(pkt, peerId: peer)),
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
      onReply: (peer, pkt) => unawaited(sender.handleInbound(pkt, peerId: peer)),
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
      onReply: (peer, pkt) => unawaited(sender.handleInbound(pkt, peerId: peer)),
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
}
