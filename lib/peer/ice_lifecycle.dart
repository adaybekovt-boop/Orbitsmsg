// ICE connection lifecycle guard (audit Round 5 A.5).
//
// flutter_webrtc surfaces raw RTCPeerConnection state callbacks, but nothing
// bounded how long a link may sit in ICE `checking`, or how long a
// `disconnected` link is given to self-heal — so zombie peer connections
// could linger forever, holding ports, timers and memory.
//
// This guard turns the raw state stream into a policy:
//
//   new / checking ──(checkingBudget)──────────────▶ giveUp
//   checking → connected/completed ────────────────▶ disarm (healthy)
//   connected → disconnected ──(disconnectedGrace)─▶ giveUp
//   disconnected → connected ──────────────────────▶ disarm (recovered)
//   failed / closed ───────────────────────────────▶ giveUp immediately
//
// Pure Dart + injectable timer factory so the policy is testable without a
// real WebRTC stack.

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCIceConnectionState;

class IceLifecycleGuard {
  IceLifecycleGuard({
    required void Function() onGiveUp,
    this.checkingBudget = const Duration(seconds: 20),
    this.disconnectedGrace = const Duration(seconds: 10),
  })  : _onGiveUp = onGiveUp,
        _schedule = ((Duration d, void Function() cb) => Timer(d, cb));

  /// Test seam — injects a fake scheduler instead of real [Timer]s.
  IceLifecycleGuard.withScheduler({
    required void Function() onGiveUp,
    this.checkingBudget = const Duration(seconds: 20),
    this.disconnectedGrace = const Duration(seconds: 10),
    required Timer Function(Duration, void Function()) scheduleTimer,
  })  : _onGiveUp = onGiveUp,
        _schedule = scheduleTimer;

  final void Function() _onGiveUp;
  final Duration checkingBudget;
  final Duration disconnectedGrace;
  final Timer Function(Duration, void Function()) _schedule;

  Timer? _budgetTimer;
  bool _disposed = false;
  bool _fired = false;
  RTCIceConnectionState _last = RTCIceConnectionState.RTCIceConnectionStateNew;

  RTCIceConnectionState get lastState => _last;

  /// Feed the latest ICE connection state.
  void update(RTCIceConnectionState state) {
    if (_disposed || _fired) return;
    _last = state;
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _cancel();
        break;
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        // Terminal — fire immediately; the owner tears the pc down.
        _fire();
        break;
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        // Grace window to self-recover (network flap) before declaring dead.
        if (_budgetTimer == null) _arm(disconnectedGrace);
        break;
      case RTCIceConnectionState.RTCIceConnectionStateNew:
      case RTCIceConnectionState.RTCIceConnectionStateChecking:
      default:
        if (_budgetTimer == null) _arm(checkingBudget);
        break;
    }
  }

  void _arm(Duration d) {
    _cancel();
    _budgetTimer = _schedule(d, () {
      _budgetTimer = null;
      if (_disposed) return;
      _fire();
    });
  }

  void _fire() {
    if (_fired || _disposed) return;
    _fired = true;
    _cancel();
    _onGiveUp();
  }

  void _cancel() {
    _budgetTimer?.cancel();
    _budgetTimer = null;
  }

  /// Stop all timers. The guard never fires after disposal.
  void dispose() {
    _disposed = true;
    _cancel();
  }
}
