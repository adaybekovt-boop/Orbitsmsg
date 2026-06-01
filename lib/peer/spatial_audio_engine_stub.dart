// Non-web fallback for [SpatialAudioEngine] (mobile/desktop, and any target
// without dart:html). Spatial positioning is visual + networked only here; the
// per-peer volume stays at the WebRTC call's native level. No Web Audio graph.

import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;

import 'spatial_audio_engine.dart';

SpatialAudioEngine createSpatialAudioEngineImpl() => _NoopSpatialAudioEngine();

class _NoopSpatialAudioEngine implements SpatialAudioEngine {
  @override
  void attachPeer(String peerId, MediaStream stream) {}

  @override
  void updatePeer(String peerId, {required double pan, required double gain}) {}

  @override
  void detachPeer(String peerId) {}

  @override
  void dispose() {}
}
