// Behavioral proof that chat / contact / text never request platform audio.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:orbits_flutter/peer/webrtc_audio_lifecycle.dart';

class _RecordingPc implements RTCPeerConnection {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeTrack implements MediaStreamTrack {
  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeStream implements MediaStream {
  @override
  List<MediaStreamTrack> getTracks() => <MediaStreamTrack>[_FakeTrack()];

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late WebRtcAudioLifecycle life;

  setUp(() {
    life = WebRtcAudioLifecycle(
      createPeerConnectionFn: (config, [constraints = const {}]) async {
        return _RecordingPc();
      },
      getUserMediaFn: (constraints) async {
        throw const WebRtcAudioException('init_failed', 'media forbidden');
      },
      platformAudioProbe: () => false,
    );
    WebRtcAudioLifecycle.resetForTest(next: life);
  });

  tearDown(WebRtcAudioLifecycle.resetForTest);

  test('opening a data channel does not request platform audio', () async {
    final pc = await life.createPeerConnectionFor(
      <String, dynamic>{'sdpSemantics': 'unified-plan'},
      kind: WebRtcPeerKind.dataOnly,
    );
    expect(pc, isA<RTCPeerConnection>());
    expect(life.dataPeerConnectionCount, 1);
    expect(life.platformAudioRequested, isFalse);
    expect(life.userMediaCount, 0);
  });

  test('ten chat open/close cycles never init platform ADM', () async {
    for (var i = 0; i < 10; i++) {
      final pc = await life.createPeerConnectionFor(
        <String, dynamic>{},
        kind: WebRtcPeerKind.dataOnly,
      );
      await life.releasePeerConnection(pc);
    }
    expect(life.dataPeerConnectionCount, 10);
    expect(life.platformAudioRequests, 0);
    expect(life.userMediaCount, 0);
    expect(life.liveLocalStreams, 0);
  });

  test('text-path helper does not call getUserMedia', () async {
    await life.createPeerConnectionFor(
      <String, dynamic>{},
      kind: WebRtcPeerKind.dataOnly,
    );
    expect(life.userMediaCount, 0);
    expect(life.platformAudioRequests, 0);
    expect(life.mediaPeerConnectionCount, 0);
  });

  test('call without audio returns a controlled error and stays clean', () async {
    await expectLater(
      life.acquireUserMedia(audio: true, video: false),
      throwsA(
        isA<WebRtcAudioException>().having((e) => e.code, 'code', 'no_device'),
      ),
    );
    expect(life.userMediaCount, 1);
    expect(life.liveLocalStreams, 0);
    expect(life.callStarting, isFalse);
  });

  test('cancel during acquire releases the stream', () async {
    var gen = 1;
    final withAudio = WebRtcAudioLifecycle(
      createPeerConnectionFn: (config, [constraints = const {}]) async {
        return _RecordingPc();
      },
      getUserMediaFn: (constraints) async {
        gen = 2;
        return _FakeStream();
      },
      platformAudioProbe: () => true,
    );
    await expectLater(
      withAudio.acquireUserMedia(
        audio: true,
        video: false,
        generation: 1,
        currentGeneration: () => gen,
      ),
      throwsA(
        isA<WebRtcAudioException>().having((e) => e.code, 'code', 'cancelled'),
      ),
    );
    expect(withAudio.liveLocalStreams, 0);
  });

  test('double start is rejected while a call is starting', () async {
    final blocker = Completer<MediaStream>();
    final slow = WebRtcAudioLifecycle(
      getUserMediaFn: (_) => blocker.future,
      platformAudioProbe: () => true,
    );
    final first = slow.acquireUserMedia(audio: true, video: false);
    await expectLater(
      slow.acquireUserMedia(audio: true, video: false),
      throwsA(isA<WebRtcAudioException>().having((e) => e.code, 'code', 'busy')),
    );
    blocker.completeError(const WebRtcAudioException('init_failed', 'stop'));
    await expectLater(first, throwsA(isA<WebRtcAudioException>()));
    expect(slow.callStarting, isFalse);
  });

  test('injected PeerJS data path still records data-only, never media', () {
    life.recordPeerConnection(WebRtcPeerKind.dataOnly);
    life.recordPeerConnection(WebRtcPeerKind.dataOnly);
    expect(life.dataPeerConnectionCount, 2);
    expect(life.platformAudioRequests, 0);
    expect(life.userMediaCount, 0);
  });

  test('Linux probe is false when Pulse and ALSA are absent', () async {
    final host = WebRtcAudioLifecycle(
      platformAudioProbe: platformAudioAvailable,
      getUserMediaFn: (_) async => throw StateError('must not reach getUserMedia'),
    );
    await expectLater(
      host.acquireUserMedia(audio: true, video: false),
      throwsA(
        isA<WebRtcAudioException>().having((e) => e.code, 'code', 'no_device'),
      ),
    );
  });

  test('data-only SDP constraints refuse audio and video receive', () {
    final mandatory = kDataOnlySdpConstraints['mandatory'] as Map;
    expect(mandatory['OfferToReceiveAudio'], isFalse);
    expect(mandatory['OfferToReceiveVideo'], isFalse);
  });
}
