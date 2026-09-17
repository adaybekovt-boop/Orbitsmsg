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

  /// Room-voice mesh signals ride the Hyperswarm `call` channel with
  /// `media.channel == 'room-voice'` and a `rv-` callId. 1:1 calls must
  /// ignore them so a room join does not open the personal overlay.
  bool get isRoomVoice =>
      media?['channel'] == 'room-voice' ||
      (callId.startsWith('rv-') && !callId.contains('://'));

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
    final callId = json['callId'] as String? ?? '';
    if (callId.isEmpty || callId.contains('://')) {
      throw FormatException('call signal contains forbidden fields');
    }
    return CallSignal(
      type: type,
      callId: callId,
      sdp: json['sdp'] as String?,
      candidate: candidate,
      media: media,
    );
  }
}

/// Offer / answer / ICE / hangup without PeerJS MediaConnection types.
/// Media still uses flutter_webrtc after these signals land.
class NativeCallSession {
  NativeCallSession({required this.send, this.defaultMedia});

  final Future<void> Function(CallSignal signal) send;
  final Map<String, Object?>? defaultMedia;
  CallSignalType? lastApplied;
  String? callId;
  String? remoteSdp;
  Map<String, Object?>? remoteMedia;
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
        media: media ?? defaultMedia,
      ),
    );
  }

  Future<void> accept({required String sdp}) {
    final id = callId ?? '';
    return send(
      CallSignal(
        type: CallSignalType.answer,
        callId: id,
        sdp: sdp,
        media: defaultMedia,
      ),
    );
  }

  Future<void> addIce(Map<String, Object?> candidate) {
    return send(
      CallSignal(
        type: CallSignalType.iceCandidate,
        callId: callId ?? '',
        candidate: candidate,
        media: defaultMedia,
      ),
    );
  }

  Future<void> hangup() async {
    closed = true;
    await send(
      CallSignal(
        type: CallSignalType.hangup,
        callId: callId ?? '',
        media: defaultMedia,
      ),
    );
  }

  /// Mute / camera / screen-share flags on the Hyperswarm `call` channel.
  /// Track `enabled` still flips locally; this is for the remote overlay.
  Future<void> publishMediaState({
    required bool micEnabled,
    required bool videoEnabled,
    required bool screenSharing,
  }) {
    final id = callId ?? '';
    if (id.isEmpty || id.contains('://')) return Future<void>.value();
    return send(
      CallSignal(
        type: CallSignalType.mediaState,
        callId: id,
        media: <String, Object?>{
          ...?defaultMedia,
          'mic': micEnabled,
          'video': videoEnabled,
          'screen': screenSharing,
        },
      ),
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
      case CallSignalType.mediaState:
        remoteMedia = signal.media;
      case CallSignalType.accept:
        break;
    }
  }
}
