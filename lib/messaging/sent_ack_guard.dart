// Sent-message ack guard (audit Round 5 A.2).
//
// `dc.send()` returning true means "accepted into the SCTP buffer", NOT
// "delivered". Historically the sender flipped the row to `'sent'` at that
// moment and never looked again — if the DataChannel died before the
// receiver's ack, the message was stranded in `'sent'` forever: invisible to
// the outbox (which only retries `'pending'`) while showing a sent-tick in
// the UI.
//
// [SentAckGuard] closes that window: arming a msgId schedules a demotion;
// the demotion flips any row still stuck in `'sent'` back to `'pending'` so
// the next outbox flush re-sends it. An inbound ack calls `confirm()` which
// cancels the pending demotion.

import 'dart:async';

class SentAckGuard {
  SentAckGuard({
    required Future<void> Function(String msgId) onDemote,
    this.timeout = const Duration(seconds: 30),
  })  : _onDemote = onDemote,
        _schedule = ((Duration d, void Function() cb) => Timer(d, cb));

  /// Test seam — injects a fake scheduler instead of real [Timer]s.
  SentAckGuard.withScheduler({
    required Future<void> Function(String msgId) onDemote,
    this.timeout = const Duration(seconds: 30),
    required Timer Function(Duration, void Function()) scheduleTimer,
  })  : _onDemote = onDemote,
        _schedule = scheduleTimer;

  final Future<void> Function(String msgId) _onDemote;
  final Duration timeout;
  final Timer Function(Duration, void Function()) _schedule;

  final Map<String, Timer> _timers = <String, Timer>{};

  int get armedCount => _timers.length;

  /// The send path just wrote status `'sent'` for [msgId]. Arm the demotion.
  /// Re-arming the same id resets its deadline (outbox retry re-send).
  void arm(String msgId) {
    if (msgId.isEmpty) return;
    disarm(msgId);
    _timers[msgId] = _schedule(timeout, () => _expire(msgId));
  }

  /// An ack arrived for [msgId] (any flavour — `'sent'` or `'delivered'`).
  /// The receiver has it; no demotion needed.
  void confirm(String msgId) => disarm(msgId);

  Future<void> _expire(String msgId) async {
    _timers.remove(msgId);
    await _onDemote(msgId);
  }

  void disarm(String msgId) {
    _timers.remove(msgId)?.cancel();
  }

  /// Cancel everything (notifier dispose / logout).
  Future<void> dispose() async {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }
}
