// Retained flutter_webrtc peer connection for Hyperswarm `call` signaling.
// Offer / answer / ICE travel on NativeCallSession. This is not TURN and
// not PeerJS MediaConnection.

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../peer/signaling.dart';
import 'hyperswarm_signaling.dart';

/// STUN from the shared PeerEnv list. TURN is still required for some NATs.
Map<String, dynamic> nativeRtcConfiguration() => <String, dynamic>{
      'sdpSemantics': 'unified-plan',
      'iceServers': defaultIceServers,
    };

Map<String, Object?> iceCandidateToJson({
  required String candidate,
  String? sdpMid,
  int? sdpMLineIndex,
}) =>
    <String, Object?>{
      'candidate': candidate,
      if (sdpMid != null) 'sdpMid': sdpMid,
      if (sdpMLineIndex != null) 'sdpMLineIndex': sdpMLineIndex,
    };

bool isCompleteIceCandidate(Map<String, Object?> json) {
  final c = json['candidate'];
  return c is String && c.isNotEmpty;
}

RTCIceCandidate rtcIceCandidateFromJson(Map<String, Object?> json) {
  final idx = json['sdpMLineIndex'];
  final line = idx is int ? idx : (idx is num ? idx.toInt() : null);
  return RTCIceCandidate(
    json['candidate'] as String?,
    json['sdpMid'] as String?,
    line,
  );
}

/// Trickle ICE must wait until [setRemoteDescription] has run.
class NativeIceBuffer {
  bool remoteDescriptionSet = false;
  final List<Map<String, Object?>> pending = <Map<String, Object?>>[];

  List<Map<String, Object?>> ingest(Map<String, Object?> candidate) {
    if (!isCompleteIceCandidate(candidate)) return const [];
    if (!remoteDescriptionSet) {
      pending.add(Map<String, Object?>.from(candidate));
      return const [];
    }
    return [candidate];
  }

  List<Map<String, Object?>> markRemoteDescriptionSet() {
    remoteDescriptionSet = true;
    final out = List<Map<String, Object?>>.from(pending);
    pending.clear();
    return out;
  }
}

/// Owns the RTCPeerConnection for one native 1:1 call.
class NativeCallMedia {
  NativeCallMedia({
    required this.session,
    required this.onRemoteStream,
    Map<String, dynamic>? rtcConfiguration,
  }) : rtcConfiguration = rtcConfiguration ?? nativeRtcConfiguration();

  final NativeCallSession session;
  final void Function(MediaStream stream) onRemoteStream;
  final Map<String, dynamic> rtcConfiguration;
  final NativeIceBuffer ice = NativeIceBuffer();
  RTCPeerConnection? peerConnection;

  Future<void> attachLocal(MediaStream local) async {
    peerConnection ??= await createPeerConnection(rtcConfiguration);
    _wire(peerConnection!);
    for (final track in local.getTracks()) {
      await peerConnection!.addTrack(track, local);
    }
  }

  void _wire(RTCPeerConnection pc) {
    pc.onIceCandidate = (cand) {
      final c = cand.candidate;
      if (c == null || c.isEmpty) return;
      unawaited(
        session.addIce(
          iceCandidateToJson(
            candidate: c,
            sdpMid: cand.sdpMid,
            sdpMLineIndex: cand.sdpMLineIndex,
          ),
        ),
      );
    };
    pc.onTrack = (event) {
      if (event.streams.isEmpty) return;
      onRemoteStream(event.streams.first);
    };
  }

  Future<String> createOfferSdp() async {
    final pc = peerConnection;
    if (pc == null) return 'v=0';
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    return offer.sdp ?? 'v=0';
  }

  Future<String> createAnswerSdp(String remoteOffer) async {
    final pc = peerConnection;
    if (pc == null) return 'v=0';
    await pc.setRemoteDescription(RTCSessionDescription(remoteOffer, 'offer'));
    await _flushIce();
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    return answer.sdp ?? 'v=0';
  }

  Future<void> setRemoteAnswer(String sdp) async {
    final pc = peerConnection;
    if (pc == null || sdp.isEmpty) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    await _flushIce();
  }

  Future<void> addRemoteIce(Map<String, Object?> candidate) async {
    for (final ready in ice.ingest(candidate)) {
      await _applyIce(ready);
    }
  }

  Future<void> _flushIce() async {
    for (final ready in ice.markRemoteDescriptionSet()) {
      await _applyIce(ready);
    }
  }

  Future<void> _applyIce(Map<String, Object?> json) async {
    final pc = peerConnection;
    if (pc == null) return;
    try {
      await pc.addCandidate(rtcIceCandidateFromJson(json));
    } catch (_) {}
  }

  Future<void> close() async {
    try {
      await peerConnection?.close();
    } catch (_) {}
    peerConnection = null;
  }
}
