// Owns when WebRTC may touch a platform Audio Device Module.
//
// Opening a chat, adding a contact, or sending text must never request
// microphone / PulseAudio / ALSA. Those paths may create a *data-only*
// RTCPeerConnection (PeerJS DataChannel). The Linux plugin is patched so
// that factory init uses WebRTC's Dummy ADM, not the Pulse/ALSA module
// that Fatals in adm_helpers.cc:39 when no sound server is present.
//
// Platform capture (getUserMedia, real ADM) is allowed only after an
// explicit start-call / accept-call action.

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'webrtc_audio_platform_io.dart'
    if (dart.library.html) 'webrtc_audio_platform_web.dart';

enum WebRtcPeerKind {
  /// ICE + DataChannel only. Must not initialize platform audio.
  dataOnly,

  /// Audio/video call. May request the platform ADM.
  media,
}

/// SDP constraints for DataChannel-only offers/answers. Explicitly refuse
/// audio/video receive so Dummy ADM / PulseAudio is never touched during chat.
const Map<String, dynamic> kDataOnlySdpConstraints = <String, dynamic>{
  'mandatory': <String, dynamic>{
    'OfferToReceiveAudio': false,
    'OfferToReceiveVideo': false,
  },
};

class WebRtcAudioException implements Exception {
  const WebRtcAudioException(this.code, this.message);

  final String code;
  final String message;

  String get userMessage {
    switch (code) {
      case 'no_device':
        return 'Аудиоустройство недоступно. Чат и файлы работают, звонок отменён.';
      case 'permission':
        return 'Нет доступа к микрофону';
      case 'init_failed':
        return 'Не удалось запустить аудиозвонок';
      case 'cancelled':
        return 'Звонок отменён';
      default:
        return message;
    }
  }

  @override
  String toString() => 'WebRtcAudioException($code): $message';
}

typedef CreateRtcPeerConnection = Future<RTCPeerConnection> Function(
  Map<String, dynamic> configuration, [
  Map<String, dynamic> constraints,
]);

typedef GetUserMediaFn = Future<MediaStream> Function(
  Map<String, dynamic> constraints,
);

/// Process-wide gate. Tests replace [instance].
class WebRtcAudioLifecycle {
  WebRtcAudioLifecycle({
    CreateRtcPeerConnection? createPeerConnectionFn,
    GetUserMediaFn? getUserMediaFn,
    bool Function()? platformAudioProbe,
  })  : _createPeerConnectionFn = createPeerConnectionFn ?? createPeerConnection,
        _getUserMediaFn = getUserMediaFn ?? _defaultGetUserMedia,
        _platformAudioProbe = platformAudioProbe ?? platformAudioAvailable;

  static WebRtcAudioLifecycle instance = WebRtcAudioLifecycle();

  static void resetForTest({WebRtcAudioLifecycle? next}) {
    instance = next ?? WebRtcAudioLifecycle();
  }

  final CreateRtcPeerConnection _createPeerConnectionFn;
  final GetUserMediaFn _getUserMediaFn;
  final bool Function() _platformAudioProbe;

  int dataPeerConnectionCount = 0;
  int mediaPeerConnectionCount = 0;
  int userMediaCount = 0;
  int platformAudioRequests = 0;
  int liveLocalStreams = 0;
  bool callStarting = false;

  /// True after an explicit call action asked for capture.
  bool get platformAudioRequested => platformAudioRequests > 0;

  void recordPeerConnection(WebRtcPeerKind kind) {
    if (kind == WebRtcPeerKind.media) {
      mediaPeerConnectionCount += 1;
      platformAudioRequests += 1;
    } else {
      dataPeerConnectionCount += 1;
    }
  }

  Future<RTCPeerConnection> createPeerConnectionFor(
    Map<String, dynamic> configuration, {
    required WebRtcPeerKind kind,
    Map<String, dynamic> constraints = const <String, dynamic>{},
  }) async {
    recordPeerConnection(kind);
    return _createPeerConnectionFn(configuration, constraints);
  }

  Future<MediaStream> acquireUserMedia({
    required bool audio,
    required bool video,
    int generation = 0,
    int Function()? currentGeneration,
  }) async {
    if (callStarting) {
      throw const WebRtcAudioException(
        'busy',
        'Звонок уже запускается',
      );
    }
    callStarting = true;
    platformAudioRequests += 1;
    userMediaCount += 1;
    try {
      if (audio && !_platformAudioProbe()) {
        throw const WebRtcAudioException(
          'no_device',
          'no platform audio device',
        );
      }
      final stream = await _getUserMediaFn({
        'audio': audio,
        'video': video,
      });
      if (currentGeneration != null && currentGeneration() != generation) {
        await releaseStream(stream);
        throw const WebRtcAudioException('cancelled', 'call cancelled');
      }
      liveLocalStreams += 1;
      return stream;
    } on WebRtcAudioException {
      rethrow;
    } catch (e) {
      throw WebRtcAudioException('init_failed', e.toString());
    } finally {
      callStarting = false;
    }
  }

  Future<void> releaseStream(MediaStream? stream) async {
    if (stream == null) return;
    try {
      for (final track in stream.getTracks()) {
        try {
          await track.stop();
        } catch (_) {}
      }
    } catch (_) {}
    try {
      await stream.dispose();
    } catch (_) {}
    if (liveLocalStreams > 0) liveLocalStreams -= 1;
  }

  Future<void> releasePeerConnection(RTCPeerConnection? pc) async {
    if (pc == null) return;
    try {
      await pc.close();
    } catch (_) {}
    try {
      await pc.dispose();
    } catch (_) {}
  }
}

Future<MediaStream> _defaultGetUserMedia(Map<String, dynamic> constraints) {
  return navigator.mediaDevices.getUserMedia(constraints);
}

bool platformAudioAvailable() => orbitsPlatformAudioAvailable();
