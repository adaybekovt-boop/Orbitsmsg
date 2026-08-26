// Round 5 A.2 вЂ” outbound 'sent' must not be terminal without an ack.
//
// Behavioral contract:
//   1. A message handed to the transport ('sent') whose ack never arrives is
//      demoted back to 'pending' after the deadline в†’ outbox can retry.
//   2. An arriving ack (any flavour) cancels the demotion вЂ” a delivered
//      message is never re-queued.
//   3. Re-sending (outbox flush) re-arms the deadline; a late ack still wins.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/messaging/sent_ack_guard.dart';
import 'package:orbits_flutter/storage/db.dart' as db;
import 'package:drift/native.dart';
import 'package:orbits_flutter/storage/database.dart'
    show OrbitsDatabase, setOrbitsDatabase, closeOrbitsDatabase;
import 'package:orbits_flutter/core/vault_kek.dart'
    show setVaultKek, clearVaultKek;

class _FakeTimer implements Timer {
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}
class _FakeScheduler {
  final List<({Duration at, void Function() cb, _FakeTimer handle})> pending =
      [];

  Timer schedule(Duration d, void Function() cb) {
    final handle = _FakeTimer();
    pending.add((at: d, cb: cb, handle: handle));
    return handle;
  }

  void elapse(Duration upTo) {
    final due = pending
        .where((e) => e.at <= upTo && !e.handle.cancelled)
        .toList(growable: false);
    pending.removeWhere((e) => e.at <= upTo || e.handle.cancelled);
    for (final e in due) {
      e.cb();
    }
  }
}
void main() {
  late OrbitsDatabase database;
  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 7 + 1) & 0xff));
  });
  tearDown(() async {
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  Future<Map<String, Object?>?> statusOf(String id) => db.getMessageById(id);

  test('unacked sent message is demoted to pending after the deadline',
      () async {
    final sched = _FakeScheduler();
    final guard = SentAckGuard.withScheduler(
      timeout: const Duration(seconds: 30),
      scheduleTimer: sched.schedule,
      onDemote: (msgId) async {
        final row = await db.getMessageById(msgId);
        if (row != null && row['status'] == 'sent') {
          await db.updateMessageStatus(msgId, 'pending');
        }
      },
    );

    // Simulate the live send path: channel open в†’ row persisted as 'sent'.
    const msgId = 'self:1000:aaaa1111';
    await db.saveMessage({
      'id': msgId,
      'peerId': 'ORBIT-PEER01',
      'timestamp': 1000,
      'direction': 'out',
      'status': 'sent', // pre-fix: this is where it stays forever
      'payload': {'type': 'text', 'text': 'hello'},
    });
    guard.arm(msgId);

    // Deadline passes with NO ack.
    sched.elapse(const Duration(seconds: 30));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final row = await statusOf(msgId);
    expect(row!['status'], 'pending',
        reason:
            'a sent-but-unacked message must return to the retry queue, '
            'not strand in sent forever');
    await guard.dispose();
  });

  test('arriving ack cancels demotion вЂ” delivered never re-queued', () async {
    final sched = _FakeScheduler();
    final guard = SentAckGuard.withScheduler(
      timeout: const Duration(seconds: 30),
      scheduleTimer: sched.schedule,
      onDemote: (msgId) async {
        final row = await db.getMessageById(msgId);
        if (row != null && row['status'] == 'sent') {
          await db.updateMessageStatus(msgId, 'pending');
        }
      },
    );

    const msgId = 'self:2000:bbbb2222';
    await db.saveMessage({
      'id': msgId,
      'peerId': 'ORBIT-PEER02',
      'timestamp': 2000,
      'direction': 'out',
      'status': 'sent',
      'payload': {'type': 'text', 'text': 'hi'},
    });
    guard.arm(msgId);

    // Receiver acks at t+10s.
    sched.elapse(const Duration(seconds: 10));
    await Future<void>.delayed(Duration.zero);
    guard.confirm(msgId); // what queueAckStatus does on an inbound ack

    sched.elapse(const Duration(hours: 1)); // deadline blows past
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final row = await statusOf(msgId);
    expect(row!['status'], 'sent',
        reason: 'acked message must keep its sent status');
    await guard.dispose();
  });

  test('outbox re-send re-arms; ack after re-send still wins', () async {
    final sched = _FakeScheduler();
    final guard = SentAckGuard.withScheduler(
      timeout: const Duration(seconds: 30),
      scheduleTimer: sched.schedule,
      onDemote: (msgId) async {
        final row = await db.getMessageById(msgId);
        if (row != null && row['status'] == 'sent') {
          await db.updateMessageStatus(msgId, 'pending');
        }
      },
    );

    const msgId = 'self:3000:cccc3333';
    await db.saveMessage({
      'id': msgId,
      'peerId': 'ORBIT-PEER03',
      'timestamp': 3000,
      'direction': 'out',
      'status': 'pending',
      'payload': {'type': 'text', 'text': 'retry me'},
    });

    // First attempt at t=0.
    guard.arm(msgId);
    sched.elapse(const Duration(seconds: 30));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await db.updateMessageStatus(msgId, 'pending'); // demoted by expiry
    expect((await statusOf(msgId))!['status'], 'pending');

    // Outbox flush retries: sendEncrypted ok в†’ 'sent' + re-arm.
    await db.updateMessageStatus(msgId, 'sent');
    guard.arm(msgId);
    // Ack arrives before the new deadline.
    sched.elapse(const Duration(seconds: 20));
    await Future<void>.delayed(Duration.zero);
    guard.confirm(msgId);
    await db.updateMessageStatus(msgId, 'delivered');

    sched.elapse(const Duration(hours: 1));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect((await statusOf(msgId))!['status'], 'delivered',
        reason: 'late ack must win over the re-armed deadline');
    await guard.dispose();
  });

  test('dispose cancels all armed deadlines without firing demotions',
      () async {
    final sched = _FakeScheduler();
    var demotes = 0;
    final guard = SentAckGuard.withScheduler(
      timeout: const Duration(seconds: 5),
      scheduleTimer: sched.schedule,
      onDemote: (_) async => demotes++,
    );
    guard.arm('m1');
    guard.arm('m2');
    expect(guard.armedCount, 2);
    await guard.dispose();
    sched.elapse(const Duration(hours: 1));
    await Future<void>.delayed(Duration.zero);
    expect(demotes, 0);
  });
}

