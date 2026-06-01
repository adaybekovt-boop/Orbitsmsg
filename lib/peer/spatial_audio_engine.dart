// Spatial-audio engine (Phase 4 — voice rooms).
//
// Routes each remote voice peer's WebRTC media stream through a stereo
// panner + gain node so a balloon's position on the SpatialAudioCanvas becomes
// real positional audio:
//   • pan  ∈ [-1, 1]  — stereo balance (−1 left ear … +1 right ear) = balloon X
//   • gain ∈ [0, 1]   — distance attenuation = clamp(1 − √(x²+y²), 0, 1)
//
// Web uses the Web Audio API (StereoPannerNode + GainNode). Every other
// platform gets a no-op fallback: the visual drag and the P2P coordinate sync
// still work, and WebRTC keeps playing the stream at its native level (the
// "safe fallback" called for on iOS/Android).
//
// The concrete impl is chosen at compile time via a conditional import so the
// dart:html / dart:web_audio code never reaches a mobile/desktop build.

import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;

import 'spatial_audio_engine_stub.dart'
    if (dart.library.js_interop) 'spatial_audio_engine_web.dart';

abstract class SpatialAudioEngine {
  /// Route [stream] (a remote peer's audio) through the engine, keyed by
  /// [peerId]. Idempotent — re-attaching the same peer rebuilds its nodes.
  void attachPeer(String peerId, MediaStream stream);

  /// Apply positional audio for [peerId]: [pan] ∈ [-1,1] (L→R) and
  /// [gain] ∈ [0,1] (distance attenuation). No-op if the peer isn't attached.
  void updatePeer(String peerId, {required double pan, required double gain});

  /// Stop routing [peerId] and release its audio nodes.
  void detachPeer(String peerId);

  /// Tear everything down (detach all peers, close the AudioContext).
  void dispose();
}

/// Build the platform engine: Web Audio on web, no-op elsewhere.
SpatialAudioEngine createSpatialAudioEngine() => createSpatialAudioEngineImpl();
