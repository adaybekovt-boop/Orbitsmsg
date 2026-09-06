// Idempotent native call signaling. Media stays WebRTC. Handles are opaque.

import 'hyperswarm_signaling.dart';

enum NativeCallPhase {
  idle,
  offering,
  ringing,
  connecting,
  connected,
  ending,
  closed,
}

class NativeCallMachine {
  NativeCallMachine({
    required this.send,
    this.nowMs,
    this.offerTimeoutMs = 30 * 1000,
  });

  final Future<void> Function(CallSignal signal) send;
  final int Function()? nowMs;
  final int offerTimeoutMs;

  NativeCallPhase phase = NativeCallPhase.idle;
  String? callId;
  String? remoteSdp;
  final List<Map<String, Object?>> remoteIce = <Map<String, Object?>>[];
  final Set<String> appliedKeys = <String>{};
  bool closed = false;
  int? offerStartedAt;

  String _key(CallSignal signal) =>
      '${signal.type.name}:${signal.callId}:${signal.sdp ?? ''}:${signal.candidate}';

  bool get timedOut {
    final started = offerStartedAt;
    if (started == null) return false;
    final now = nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;
    return now - started > offerTimeoutMs;
  }

  Future<void> startOutgoing({
    required String callId,
    required String sdp,
    Map<String, Object?>? media,
  }) async {
    if (phase != NativeCallPhase.idle && phase != NativeCallPhase.closed) {
      return;
    }
    this.callId = callId;
    phase = NativeCallPhase.offering;
    offerStartedAt = nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;
    await send(
      CallSignal(
        type: CallSignalType.offer,
        callId: callId,
        sdp: sdp,
        media: media,
      ),
    );
  }

  Future<void> accept({required String sdp}) async {
    if (phase == NativeCallPhase.closed) return;
    phase = NativeCallPhase.connecting;
    await send(
      CallSignal(type: CallSignalType.answer, callId: callId ?? '', sdp: sdp),
    );
    phase = NativeCallPhase.connected;
  }

  Future<void> reject() async {
    if (closed) return;
    phase = NativeCallPhase.ending;
    await send(CallSignal(type: CallSignalType.reject, callId: callId ?? ''));
    _close();
  }

  Future<void> hangup() async {
    if (closed) return;
    phase = NativeCallPhase.ending;
    await send(CallSignal(type: CallSignalType.hangup, callId: callId ?? ''));
    _close();
  }

  Future<void> addIce(Map<String, Object?> candidate) {
    return send(
      CallSignal(
        type: CallSignalType.iceCandidate,
        callId: callId ?? '',
        candidate: candidate,
      ),
    );
  }

  void applyRemote(CallSignal signal) {
    if (closed &&
        signal.type != CallSignalType.hangup &&
        signal.type != CallSignalType.reject) {
      return;
    }
    final key = _key(signal);
    if (!appliedKeys.add(key)) return;
    callId ??= signal.callId;
    if (callId != signal.callId && signal.callId.isNotEmpty) {
      // Glare: the lexicographically smaller call id wins.
      if (signal.type == CallSignalType.offer &&
          signal.callId.compareTo(callId!) < 0) {
        callId = signal.callId;
      } else if (signal.type == CallSignalType.offer) {
        return;
      }
    }
    switch (signal.type) {
      case CallSignalType.offer:
        remoteSdp = signal.sdp;
        phase = NativeCallPhase.ringing;
      case CallSignalType.answer:
      case CallSignalType.accept:
        remoteSdp = signal.sdp ?? remoteSdp;
        phase = NativeCallPhase.connected;
      case CallSignalType.iceCandidate:
        if (signal.candidate != null) remoteIce.add(signal.candidate!);
      case CallSignalType.hangup:
      case CallSignalType.reject:
        _close();
      case CallSignalType.mediaState:
        break;
    }
  }

  void recoverAfterNetworkChange() {
    if (closed) return;
    if (phase == NativeCallPhase.offering && timedOut) {
      _close();
    }
  }

  void _close() {
    closed = true;
    phase = NativeCallPhase.closed;
  }
}
