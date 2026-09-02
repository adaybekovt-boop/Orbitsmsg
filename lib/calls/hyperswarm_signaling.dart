// Phase 6: WebRTC signaling payloads on the Hyperswarm `call` channel.
// Media still uses flutter_webrtc. This is not TURN.

import '../transport/layers.dart';

enum CallSignalType {
  offer,
  answer,
  iceCandidate,
  accept,
  reject,
  hangup,
  mediaState,
}

class CallSignal {
  const CallSignal({
    required this.type,
    required this.callId,
    this.sdp,
    this.candidate,
    this.media,
  });

  final CallSignalType type;
  final String callId;
  final String? sdp;
  final Map<String, Object?>? candidate;
  final Map<String, Object?>? media;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': type.name,
        'callId': callId,
        if (sdp != null) 'sdp': sdp,
        if (candidate != null) 'candidate': candidate,
        if (media != null) 'media': media,
      };

  static CallSignal fromJson(Map<String, Object?> json) {
    final typeName = json['type'] as String? ?? '';
    final type = CallSignalType.values.firstWhere(
      (v) => v.name == typeName,
      orElse: () => throw FormatException('bad call signal $typeName'),
    );
    final candidate = (json['candidate'] as Map?)?.cast<String, Object?>();
    final media = (json['media'] as Map?)?.cast<String, Object?>();
    if (!replicationValueIsSafe(json) ||
        !replicationValueIsSafe(candidate) ||
        !replicationValueIsSafe(media)) {
      throw FormatException('call signal contains forbidden fields');
    }
    return CallSignal(
      type: type,
      callId: json['callId'] as String? ?? '',
      sdp: json['sdp'] as String?,
      candidate: candidate,
      media: media,
    );
  }
}

/// Offer / answer / ICE / hangup without PeerJS MediaConnection types.
/// Media still uses flutter_webrtc after these signals land.
class NativeCallSession {
  NativeCallSession({required this.send});

  final Future<void> Function(CallSignal signal) send;
  CallSignalType? lastApplied;
  String? callId;
  String? remoteSdp;
  final List<Map<String, Object?>> remoteIce = <Map<String, Object?>>[];
  bool closed = false;

  Future<void> startOutgoing({
    required String callId,
    required String sdp,
    Map<String, Object?>? media,
  }) {
    this.callId = callId;
    return send(
      CallSignal(
        type: CallSignalType.offer,
        callId: callId,
        sdp: sdp,
        media: media,
      ),
    );
  }

  Future<void> accept({required String sdp}) {
    final id = callId ?? '';
    return send(CallSignal(type: CallSignalType.answer, callId: id, sdp: sdp));
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

  Future<void> hangup() async {
    closed = true;
    await send(
      CallSignal(type: CallSignalType.hangup, callId: callId ?? ''),
    );
  }

  void applyRemote(CallSignal signal) {
    lastApplied = signal.type;
    callId ??= signal.callId;
    switch (signal.type) {
      case CallSignalType.offer:
        remoteSdp = signal.sdp;
      case CallSignalType.answer:
        remoteSdp = signal.sdp;
      case CallSignalType.iceCandidate:
        if (signal.candidate != null) remoteIce.add(signal.candidate!);
      case CallSignalType.hangup:
      case CallSignalType.reject:
        closed = true;
      case CallSignalType.accept:
      case CallSignalType.mediaState:
        break;
    }
  }
}
