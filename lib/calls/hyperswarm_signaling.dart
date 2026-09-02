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

/// Real SDP: a `v=0` line plus at least one `o=` / `s=` / `m=` line.
/// Empty, bare `v=0`, and missing `v=` are not sendable.
bool isSendableCallSdp(String? sdp) {
  if (sdp == null) return false;
  final text = sdp.replaceAll('\r\n', '\n').trim();
  if (text.isEmpty || text == 'v=0') return false;
  var hasVersion = false;
  var hasSession = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line == 'v=0') hasVersion = true;
    if (line.startsWith('o=') ||
        line.startsWith('s=') ||
        line.startsWith('m=')) {
      hasSession = true;
    }
  }
  return hasVersion && hasSession;
}

/// Bind inbound call signals to the active 1:1 session. A new offer is
/// allowed while idle. Foreign [from] or a stale [callId] is dropped.
bool acceptInboundCallSignal({
  required String from,
  required CallSignal signal,
  required String? activeRemotePeerId,
  required String? sessionCallId,
  required bool sessionActive,
}) {
  if (from.isEmpty || from.contains('://')) return false;
  if (signal.isRoomVoice) return false;
  final newOfferWhileIdle =
      signal.type == CallSignalType.offer && !sessionActive;
  if (newOfferWhileIdle) return true;
  if (activeRemotePeerId != null &&
      activeRemotePeerId.isNotEmpty &&
      from != activeRemotePeerId) {
    return false;
  }
  if (sessionCallId != null &&
      sessionCallId.isNotEmpty &&
      signal.callId != sessionCallId) {
    return false;
  }
  return true;
}

/// Leftover PeerJS media is closed only when this device can use native
/// *and* the remote advertised call-v1 *and* a native session exists.
/// A cached call-v1 with no native carrier keeps the PeerJS path.
bool shouldCloseLeftoverPeerJsCall({
  required bool canUseNative,
  required bool remoteUnderstandsNativeCall,
  required bool nativeSessionExists,
}) {
  return nativeSessionExists &&
      canUseNative &&
      remoteUnderstandsNativeCall;
}

class CallSignal {
  const CallSignal({
    required this.type,
    required this.callId,
    this.sdp,
    this.candidate,
    this.media,
    this.from,
  });

  final CallSignalType type;
  final String callId;
  final String? sdp;
  final Map<String, Object?>? candidate;
  final Map<String, Object?>? media;

  /// Optional authenticated sender. DualStack passes this as [from]
  /// on the handler; the wire may omit it.
  final String? from;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': type.name,
        'callId': callId,
        if (sdp != null) 'sdp': sdp,
        if (candidate != null) 'candidate': candidate,
        if (media != null) 'media': media,
        if (from != null && from!.isNotEmpty) 'from': from,
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
    final from = json['from'] as String?;
    if (from != null && (from.isEmpty || from.contains('://'))) {
      throw FormatException('call signal contains forbidden fields');
    }
    return CallSignal(
      type: type,
      callId: callId,
      sdp: json['sdp'] as String?,
      candidate: candidate,
      media: media,
      from: from,
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

  /// Send an offer only when [sdp] is a real session description.
  Future<bool> startOutgoingIfValid({
    required String callId,
    required String sdp,
    Map<String, Object?>? media,
  }) async {
    if (!isSendableCallSdp(sdp)) return false;
    await startOutgoing(callId: callId, sdp: sdp, media: media);
    return true;
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

  Future<bool> acceptIfValid({required String sdp}) async {
    if (!isSendableCallSdp(sdp)) return false;
    await accept(sdp: sdp);
    return true;
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
