// Phase 6: WebRTC signaling payloads on the Hyperswarm `call` channel.
// Media still uses flutter_webrtc. This is not TURN.

import 'dart:async';

import 'call_media_peer.dart';

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
    return CallSignal(
      type: type,
      callId: json['callId'] as String? ?? '',
      sdp: json['sdp'] as String?,
      candidate: (json['candidate'] as Map?)?.cast<String, Object?>(),
      media: (json['media'] as Map?)?.cast<String, Object?>(),
    );
  }
}

/// Offer / answer / ICE / hangup bound to one [CallMediaPeer].
class NativeCallSession {
  NativeCallSession({
    required this.send,
    this.createPeer,
    this.onMediaConnected,
    this.onRemoteTrack,
    this.onClosed,
    this.onIce,
  });

  final Future<void> Function(CallSignal signal) send;
  final Future<CallMediaPeer> Function()? createPeer;
  final void Function()? onMediaConnected;
  final void Function(Object track)? onRemoteTrack;
  final void Function()? onClosed;
  final void Function(Map<String, Object?> candidate)? onIce;

  CallMediaPeer? peer;
  CallSignalType? lastApplied;
  String? callId;
  String? remoteSdp;
  String? localSdp;
  final List<Map<String, Object?>> remoteIce = <Map<String, Object?>>[];
  bool closed = false;
  bool mediaConnected = false;
  bool _remoteDescriptionSet = false;
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];

  Future<void> startOutgoing({
    required String callId,
    required Object localStream,
    List<Object> localTracks = const <Object>[],
    Map<String, Object?>? media,
  }) async {
    if (closed) throw StateError('call session closed');
    this.callId = callId;
    final pc = await _requirePeer();
    for (final track in localTracks) {
      await pc.addLocalTrack(track, localStream);
    }
    final offer = await pc.createOffer();
    if (offer.isFallback) {
      throw StateError(kNativeCallsUnavailable);
    }
    await pc.setLocalDescription(offer);
    localSdp = offer.sdp;
    await send(
      CallSignal(
        type: CallSignalType.offer,
        callId: callId,
        sdp: offer.sdp,
        media: media,
      ),
    );
  }

  Future<void> acceptIncoming({
    required String remoteOfferSdp,
    required Object localStream,
    List<Object> localTracks = const <Object>[],
  }) async {
    if (closed) throw StateError('call session closed');
    if (remoteOfferSdp.trim().isEmpty || remoteOfferSdp.trim() == 'v=0') {
      throw StateError(kNativeCallsUnavailable);
    }
    final pc = await _requirePeer();
    for (final track in localTracks) {
      await pc.addLocalTrack(track, localStream);
    }
    await pc.setRemoteDescription(
      CallSessionDescription(type: 'offer', sdp: remoteOfferSdp),
    );
    _remoteDescriptionSet = true;
    remoteSdp = remoteOfferSdp;
    await _flushQueuedIce();
    final answer = await pc.createAnswer();
    if (answer.isFallback) {
      throw StateError(kNativeCallsUnavailable);
    }
    await pc.setLocalDescription(answer);
    localSdp = answer.sdp;
    await send(
      CallSignal(
        type: CallSignalType.answer,
        callId: callId ?? '',
        sdp: answer.sdp,
      ),
    );
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
    if (closed) return;
    closed = true;
    try {
      await send(
        CallSignal(type: CallSignalType.hangup, callId: callId ?? ''),
      );
    } finally {
      await _closePeer();
    }
  }

  Future<void> applyRemote(CallSignal signal) async {
    if (closed &&
        signal.type != CallSignalType.hangup &&
        signal.type != CallSignalType.reject) {
      return;
    }
    if (callId != null &&
        signal.callId.isNotEmpty &&
        signal.callId != callId &&
        signal.type != CallSignalType.offer) {
      return;
    }
    lastApplied = signal.type;
    callId ??= signal.callId;
    switch (signal.type) {
      case CallSignalType.offer:
        remoteSdp = signal.sdp;
      case CallSignalType.answer:
        remoteSdp = signal.sdp;
        if (signal.sdp == null ||
            signal.sdp!.trim().isEmpty ||
            signal.sdp!.trim() == 'v=0') {
          throw StateError(kNativeCallsUnavailable);
        }
        final pc = peer;
        if (pc != null) {
          await pc.setRemoteDescription(
            CallSessionDescription(type: 'answer', sdp: signal.sdp!),
          );
          _remoteDescriptionSet = true;
          await _flushQueuedIce();
        }
      case CallSignalType.iceCandidate:
        if (signal.candidate != null) {
          remoteIce.add(signal.candidate!);
          if (_remoteDescriptionSet && peer != null) {
            await peer!.addIceCandidate(signal.candidate!);
          }
        }
      case CallSignalType.hangup:
      case CallSignalType.reject:
        closed = true;
        await _closePeer();
        onClosed?.call();
      case CallSignalType.accept:
      case CallSignalType.mediaState:
        break;
    }
  }

  Future<CallMediaPeer> _requirePeer() async {
    final existing = peer;
    if (existing != null) return existing;
    final factory = createPeer;
    if (factory == null) {
      throw StateError(kNativeCallsUnavailable);
    }
    final created = await factory();
    peer = created;
    _subs.add(
      created.iceCandidates.listen((candidate) {
        onIce?.call(candidate);
        unawaited(addIce(candidate));
      }),
    );
    _subs.add(
      created.connectionStates.listen((state) {
        if (state == 'connected') {
          mediaConnected = true;
          onMediaConnected?.call();
        }
        if (state == 'failed' || state == 'closed') {
          onClosed?.call();
        }
      }),
    );
    _subs.add(
      created.remoteTracks.listen((track) {
        onRemoteTrack?.call(track);
      }),
    );
    return created;
  }

  Future<void> _flushQueuedIce() async {
    final pc = peer;
    if (pc == null) return;
    for (final candidate in remoteIce) {
      await pc.addIceCandidate(candidate);
    }
  }

  Future<void> _closePeer() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    try {
      await peer?.close();
    } catch (_) {}
    peer = null;
  }
}
