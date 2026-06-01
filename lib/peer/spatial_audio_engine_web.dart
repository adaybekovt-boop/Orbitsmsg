// Web implementation of [SpatialAudioEngine] using the Web Audio API
// (package:web). Each remote peer's WebRTC stream is tapped via
// `MediaStreamAudioSourceNode` and routed source → StereoPanner → Gain →
// destination, so balloon coordinates drive real stereo balance + distance
// attenuation.
//
// flutter_webrtc ≥ 1.x exposes the underlying JS stream as `MediaStream.jsStream`
// (a package:web `web.MediaStream`); we read it dynamically and bail gracefully
// if the runtime shape ever differs, so a missing stream never crashes the call.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;
// package:web is a transitive dep (pulled in by flutter_webrtc's web layer);
// this file is only ever compiled for web, where it is always present.
// ignore: depend_on_referenced_packages
import 'package:web/web.dart' as web;

import 'spatial_audio_engine.dart';

SpatialAudioEngine createSpatialAudioEngineImpl() => WebSpatialAudioEngine();

class WebSpatialAudioEngine implements SpatialAudioEngine {
  web.AudioContext? _ctx;
  final Map<String, _PeerNodes> _peers = {};

  web.AudioContext _context() => _ctx ??= web.AudioContext();

  @override
  void attachPeer(String peerId, MediaStream stream) {
    try {
      final js = (stream as dynamic).jsStream;
      if (js is! web.MediaStream) return;
      detachPeer(peerId);
      final ctx = _context();
      final source = ctx.createMediaStreamSource(js);
      final panner = ctx.createStereoPanner();
      final gain = ctx.createGain();
      source.connect(panner);
      panner.connect(gain);
      gain.connect(ctx.destination);
      _peers[peerId] = _PeerNodes(source, panner, gain);
    } catch (e) {
      debugPrint('[spatial-audio] attach failed for $peerId: $e');
    }
  }

  @override
  void updatePeer(String peerId, {required double pan, required double gain}) {
    final nodes = _peers[peerId];
    final ctx = _ctx;
    if (nodes == null || ctx == null) return;
    try {
      final t = ctx.currentTime;
      nodes.panner.pan.setValueAtTime(pan.clamp(-1.0, 1.0).toDouble(), t);
      nodes.gain.gain.setValueAtTime(gain.clamp(0.0, 1.0).toDouble(), t);
    } catch (e) {
      debugPrint('[spatial-audio] update failed for $peerId: $e');
    }
  }

  @override
  void detachPeer(String peerId) {
    final nodes = _peers.remove(peerId);
    if (nodes == null) return;
    try {
      nodes.source.disconnect();
      nodes.panner.disconnect();
      nodes.gain.disconnect();
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final id in _peers.keys.toList()) {
      detachPeer(id);
    }
    try {
      _ctx?.close();
    } catch (_) {}
    _ctx = null;
  }
}

class _PeerNodes {
  _PeerNodes(this.source, this.panner, this.gain);
  final web.MediaStreamAudioSourceNode source;
  final web.StereoPannerNode panner;
  final web.GainNode gain;
}
