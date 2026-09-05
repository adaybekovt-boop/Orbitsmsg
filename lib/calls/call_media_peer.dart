// Injectable media peer for native calls. Production wraps
// flutter_webrtc. Tests use [FakeCallMediaPeer]. This is not a
// physical call by itself.

import 'dart:async';

const String kNativeCallsUnavailable =
    'Звонки через этот транспорт пока недоступны';

class CallSessionDescription {
  const CallSessionDescription({required this.type, required this.sdp});

  final String type;
  final String sdp;

  bool get isFallback => sdp.trim().isEmpty || sdp.trim() == 'v=0';
}

abstract class CallMediaPeer {
  Future<void> addLocalTrack(Object track, Object stream);
  Future<CallSessionDescription> createOffer();
  Future<CallSessionDescription> createAnswer();
  Future<void> setLocalDescription(CallSessionDescription description);
  Future<void> setRemoteDescription(CallSessionDescription description);
  Future<void> addIceCandidate(Map<String, Object?> candidate);
  Stream<Map<String, Object?>> get iceCandidates;
  Stream<String> get connectionStates;
  Stream<Object> get remoteTracks;
  Future<void> close();
  bool get closed;
}

/// Deterministic in-process peer for security / signaling tests.
class FakeCallMediaPeer implements CallMediaPeer {
  FakeCallMediaPeer({this.peerName = 'local'});

  final String peerName;
  FakeCallMediaPeer? pair;
  CallSessionDescription? localDescription;
  CallSessionDescription? remoteDescription;
  final List<Map<String, Object?>> localIce = <Map<String, Object?>>[];
  final List<Map<String, Object?>> remoteIce = <Map<String, Object?>>[];
  final List<Object> addedTracks = <Object>[];
  final _ice = StreamController<Map<String, Object?>>.broadcast();
  final _states = StreamController<String>.broadcast();
  final _tracks = StreamController<Object>.broadcast();
  bool _closed = false;
  bool _remoteSet = false;
  String connectionState = 'new';

  @override
  bool get closed => _closed;

  @override
  Stream<Map<String, Object?>> get iceCandidates => _ice.stream;

  @override
  Stream<String> get connectionStates => _states.stream;

  @override
  Stream<Object> get remoteTracks => _tracks.stream;

  @override
  Future<void> addLocalTrack(Object track, Object stream) async {
    _ensureOpen();
    addedTracks.add(track);
  }

  @override
  Future<CallSessionDescription> createOffer() async {
    _ensureOpen();
    return CallSessionDescription(type: 'offer', sdp: 'offer-from-$peerName');
  }

  @override
  Future<CallSessionDescription> createAnswer() async {
    _ensureOpen();
    if (!_remoteSet) {
      throw StateError('setRemoteDescription(offer) before createAnswer');
    }
    return CallSessionDescription(type: 'answer', sdp: 'answer-from-$peerName');
  }

  @override
  Future<void> setLocalDescription(CallSessionDescription description) async {
    _ensureOpen();
    if (description.isFallback) {
      throw StateError('refusing fallback SDP');
    }
    localDescription = description;
    _emitIce({'candidate': 'ice-$peerName-1', 'sdpMid': '0'});
  }

  @override
  Future<void> setRemoteDescription(CallSessionDescription description) async {
    _ensureOpen();
    if (description.isFallback) {
      throw StateError('refusing fallback SDP');
    }
    remoteDescription = description;
    _remoteSet = true;
    _flushQueuedIce();
    if (description.type == 'answer' ||
        (description.type == 'offer' && localDescription?.type == 'answer')) {
      emitConnected();
    }
  }

  @override
  Future<void> addIceCandidate(Map<String, Object?> candidate) async {
    _ensureOpen();
    if (!_remoteSet) {
      remoteIce.add(candidate);
      return;
    }
    remoteIce.add(candidate);
  }

  @override
  Future<void> close() async {
    _closed = true;
    connectionState = 'closed';
    _states.add('closed');
    await _ice.close();
    await _states.close();
    await _tracks.close();
  }

  void emitConnected() {
    if (_closed) return;
    connectionState = 'connected';
    _states.add('connected');
    _tracks.add('remote-track-$peerName');
  }

  void emitFailed() {
    if (_closed) return;
    connectionState = 'failed';
    _states.add('failed');
  }

  void _emitIce(Map<String, Object?> candidate) {
    localIce.add(candidate);
    _ice.add(candidate);
  }

  void _flushQueuedIce() {
    // Remote description is now set; queued candidates stay recorded.
  }

  void _ensureOpen() {
    if (_closed) throw StateError('peer connection closed');
  }
}
