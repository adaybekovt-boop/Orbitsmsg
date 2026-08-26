// Round 5 A.5 вЂ” ICE connection lifecycle policy.
//
// Drives [IceLifecycleGuard] through synthetic state sequences with an
// injected scheduler and asserts the give-up policy:
//   вЂў eternal `checking` gives up after the checking budget;
//   вЂў `connected` in time disarms;
//   вЂў `disconnected` gets a grace window, then gives up;
//   вЂў recovery from `disconnected` disarms;
//   вЂў failed/closed fire immediately;
//   вЂў dispose() mutes the guard forever.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/ice_lifecycle.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCIceConnectionState;

/// Records scheduled callbacks so tests can fire them manually (fake clock).
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

  /// Fires every still-armed callback whose delay <= [upTo], in order.
  void elapse(Duration upTo) {
    final due = pending
        .where((e) => e.at <= upTo && !e.handle.cancelled)
        .toList(growable: false);
    pending.removeWhere((e) => e.at <= upTo || e.handle.cancelled);
    for (final e in due) {
      e.cb();
    }
  }

  bool get hasArmedTimer => pending.any((e) => !e.handle.cancelled);
}
const _checking = RTCIceConnectionState.RTCIceConnectionStateChecking;
const _connected = RTCIceConnectionState.RTCIceConnectionStateConnected;
const _completed = RTCIceConnectionState.RTCIceConnectionStateCompleted;
const _disconnected = RTCIceConnectionState.RTCIceConnectionStateDisconnected;
const _failed = RTCIceConnectionState.RTCIceConnectionStateFailed;
const _closed = RTCIceConnectionState.RTCIceConnectionStateClosed;

void main() {
  test('eternal checking gives up after the checking budget', () {
    final sched = _FakeScheduler();
    var gaveUp = 0;
    final g = IceLifecycleGuard.withScheduler(
      onGiveUp: () => gaveUp++,
      checkingBudget: const Duration(seconds: 20),
      disconnectedGrace: const Duration(seconds: 10),
      scheduleTimer: sched.schedule,
    );
    g.update(_checking);

    sched.elapse(const Duration(seconds: 19));
    expect(gaveUp, 0, reason: 'still inside the budget');
    sched.elapse(const Duration(seconds: 20));
    expect(gaveUp, 1, reason: 'budget exhausted → give up');
    g.dispose();
  });

  test('connected in time disarms the checking budget', () {
    final sched = _FakeScheduler();
    var gaveUp = 0;
    final g = IceLifecycleGuard.withScheduler(
      onGiveUp: () => gaveUp++,
      checkingBudget: const Duration(seconds: 20),
      disconnectedGrace: const Duration(seconds: 10),
      scheduleTimer: sched.schedule,
    );
    g.update(_checking);
    g.update(_connected);
    expect(sched.hasArmedTimer, isFalse, reason: 'healthy в†’ no timer');
    sched.elapse(const Duration(minutes: 5));
    expect(gaveUp, 0);
    g.dispose();
  });

  test('disconnected gets a grace window then gives up; recovery disarms',
      () {
    final sched = _FakeScheduler();
    var gaveUp = 0;
    final g = IceLifecycleGuard.withScheduler(
      onGiveUp: () => gaveUp++,
      checkingBudget: const Duration(seconds: 20),
      disconnectedGrace: const Duration(seconds: 10),
      scheduleTimer: sched.schedule,
    );

    // Recovery path (via `completed`, the other healthy terminal state).
    g.update(_connected);
    g.update(_disconnected);
    expect(sched.hasArmedTimer, isTrue, reason: 'grace timer armed');
    g.update(_completed); // self-healed within the grace
    sched.elapse(const Duration(minutes: 5));
    expect(gaveUp, 0, reason: 'recovered inside the grace window');

    // Death path.
    g.update(_disconnected);
    sched.elapse(const Duration(seconds: 10));
    expect(gaveUp, 1, reason: 'grace exhausted в†’ give up');
    g.dispose();
  });

  test('failed/closed fire immediately, exactly once', () {
    final sched = _FakeScheduler();
    var gaveUp = 0;
    final g = IceLifecycleGuard.withScheduler(
      onGiveUp: () => gaveUp++,
      checkingBudget: const Duration(seconds: 20),
      disconnectedGrace: const Duration(seconds: 10),
      scheduleTimer: sched.schedule,
    );
    g.update(_failed);
    g.update(_closed); // second terminal state must not double-fire
    sched.elapse(const Duration(minutes: 5));
    expect(gaveUp, 1);
    g.dispose();
  });

  test('dispose() mutes the guard вЂ” no late give-up after teardown', () {
    final sched = _FakeScheduler();
    var gaveUp = 0;
    final g = IceLifecycleGuard.withScheduler(
      onGiveUp: () => gaveUp++,
      checkingBudget: const Duration(seconds: 20),
      disconnectedGrace: const Duration(seconds: 10),
      scheduleTimer: sched.schedule,
    );
    g.update(_checking);
    g.dispose();
    sched.elapse(const Duration(hours: 1));
    expect(gaveUp, 0, reason: 'disposed guard never fires');
  });
}

