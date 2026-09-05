import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:orbits_flutter/calls/call_media_peer.dart';
import 'package:orbits_flutter/calls/hyperswarm_signaling.dart';
import 'package:orbits_flutter/peer/webrtc_audio_lifecycle.dart';

void main() {
  test('offer flow applies local SDP and does not use v=0', () async {
    final sent = <CallSignal>[];
    final pc = FakeCallMediaPeer(peerName: 'alice');
    final session = NativeCallSession(
      send: (s) async => sent.add(s),
      createPeer: () async => pc,
    );
    await session.startOutgoing(
      callId: 'c1',
      localStream: 'stream',
      localTracks: ['mic'],
    );
    expect(session.localSdp, 'offer-from-alice');
    expect(session.localSdp, isNot('v=0'));
    expect(sent.where((s) => s.type == CallSignalType.offer), hasLength(1));
    expect(
      sent.firstWhere((s) => s.type == CallSignalType.offer).sdp,
      'offer-from-alice',
    );
    expect(pc.addedTracks, ['mic']);
    expect(session.mediaConnected, isFalse);
  });

  test('answer flow requires remote description before createAnswer', () async {
    final sent = <CallSignal>[];
    final pc = FakeCallMediaPeer(peerName: 'bob');
    final session = NativeCallSession(
      send: (s) async => sent.add(s),
      createPeer: () async => pc,
    )..callId = 'c1';
    await session.applyRemote(
      const CallSignal(type: CallSignalType.offer, callId: 'c1', sdp: 'offer-from-alice'),
    );
    await session.acceptIncoming(
      remoteOfferSdp: 'offer-from-alice',
      localStream: 'stream',
      localTracks: ['mic'],
    );
    expect(pc.remoteDescription?.sdp, 'offer-from-alice');
    expect(sent.where((s) => s.type == CallSignalType.answer), hasLength(1));
    expect(sent.singleWhere((s) => s.type == CallSignalType.answer).sdp, isNot('v=0'));
  });

  test('createAnswer without remote offer fails', () async {
    final pc = FakeCallMediaPeer(peerName: 'bob');
    expect(pc.createAnswer, throwsStateError);
  });

  test('remote ICE is applied after remote description', () async {
    final pc = FakeCallMediaPeer(peerName: 'alice');
    final session = NativeCallSession(
      send: (_) async {},
      createPeer: () async => pc,
    );
    await session.startOutgoing(callId: 'c1', localStream: 's');
    await session.applyRemote(
      const CallSignal(
        type: CallSignalType.iceCandidate,
        callId: 'c1',
        candidate: {'candidate': 'early'},
      ),
    );
    expect(session.remoteIce, hasLength(1));
    await session.applyRemote(
      const CallSignal(type: CallSignalType.answer, callId: 'c1', sdp: 'answer-from-bob'),
    );
    expect(pc.remoteIce, isNotEmpty);
    expect(session.mediaConnected, isTrue);
  });

  test('stale signal for another call is ignored', () async {
    final session = NativeCallSession(send: (_) async {})..callId = 'c1';
    await session.applyRemote(
      const CallSignal(type: CallSignalType.answer, callId: 'c-other', sdp: 'nope'),
    );
    expect(session.remoteSdp, isNull);
  });

  test('fallback SDP is refused', () async {
    final session = NativeCallSession(
      send: (_) async {},
      createPeer: () async => FakeCallMediaPeer(),
    );
    expect(
      () => session.acceptIncoming(remoteOfferSdp: 'v=0', localStream: 's'),
      throwsStateError,
    );
  });

  test('hangup closes the peer connection', () async {
    final pc = FakeCallMediaPeer(peerName: 'alice');
    final session = NativeCallSession(
      send: (_) async {},
      createPeer: () async => pc,
    );
    await session.startOutgoing(callId: 'c1', localStream: 's');
    await session.hangup();
    expect(session.closed, isTrue);
    expect(pc.closed, isTrue);
  });

  test('opening a data-only chat PC does not request platform audio', () async {
    final life = WebRtcAudioLifecycle(
      createPeerConnectionFn: (config, [constraints = const {}]) async {
        return _RecordingPc();
      },
      getUserMediaFn: (_) async {
        throw const WebRtcAudioException('init_failed', 'media forbidden');
      },
      platformAudioProbe: () => false,
    );
    WebRtcAudioLifecycle.resetForTest(next: life);
    addTearDown(WebRtcAudioLifecycle.resetForTest);
    await life.createPeerConnectionFor(
      <String, dynamic>{},
      kind: WebRtcPeerKind.dataOnly,
    );
    expect(life.platformAudioRequested, isFalse);
    expect(life.userMediaCount, 0);
  });
}

class _RecordingPc implements RTCPeerConnection {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
