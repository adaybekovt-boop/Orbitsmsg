import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/calls/hyperswarm_signaling.dart';
import 'package:orbits_flutter/calls/native_call_media.dart';

const _realSdp =
    'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n';

void main() {
  test('fake and empty SDP are not sent on the captured list', () async {
    final sent = <CallSignal>[];
    final session = NativeCallSession(send: (s) async => sent.add(s));

    expect(await session.startOutgoingIfValid(callId: 'c1', sdp: ''), isFalse);
    expect(
      await session.startOutgoingIfValid(callId: 'c1', sdp: 'v=0'),
      isFalse,
    );
    expect(
      await session.startOutgoingIfValid(
        callId: 'c1',
        sdp: 'o=- 1 2 IN IP4 127.0.0.1',
      ),
      isFalse,
    );
    expect(
      await session.startOutgoingIfValid(callId: 'c1', sdp: 'v=0-offer'),
      isFalse,
    );
    expect(sent, isEmpty);

    expect(
      await session.startOutgoingIfValid(callId: 'c1', sdp: _realSdp),
      isTrue,
    );
    expect(sent, hasLength(1));
    expect(sent.single.type, CallSignalType.offer);
    expect(isSendableCallSdp(sent.single.sdp), isTrue);

    sent.clear();
    expect(await session.acceptIfValid(sdp: 'v=0'), isFalse);
    expect(sent, isEmpty);
    expect(await session.acceptIfValid(sdp: _realSdp), isTrue);
    expect(sent.single.type, CallSignalType.answer);
  });

  test('createOfferSdp / createAnswerSdp throw when the PC is missing', () {
    final session = NativeCallSession(send: (_) async {});
    final media = NativeCallMedia(session: session, onRemoteStream: (_) {});
    expect(media.createOfferSdp(), throwsStateError);
    expect(media.createAnswerSdp(_realSdp), throwsStateError);
  });

  test('cached call-v1 without a native session keeps PeerJS', () {
    expect(
      shouldCloseLeftoverPeerJsCall(
        canUseNative: false,
        remoteUnderstandsNativeCall: true,
        nativeSessionExists: false,
      ),
      isFalse,
    );
    expect(
      shouldCloseLeftoverPeerJsCall(
        canUseNative: true,
        remoteUnderstandsNativeCall: true,
        nativeSessionExists: false,
      ),
      isFalse,
    );
    expect(
      shouldCloseLeftoverPeerJsCall(
        canUseNative: true,
        remoteUnderstandsNativeCall: true,
        nativeSessionExists: true,
      ),
      isTrue,
    );
  });

  test('hangup and ICE from another peer or stale callId are ignored', () {
    const hangup = CallSignal(type: CallSignalType.hangup, callId: 'c1');
    expect(
      acceptInboundCallSignal(
        from: 'ORBIT-BBBBBBBBBBBBBBBB',
        signal: hangup,
        activeRemotePeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        sessionCallId: 'c1',
        sessionActive: true,
      ),
      isFalse,
    );
    expect(
      acceptInboundCallSignal(
        from: 'ORBIT-AAAAAAAAAAAAAAAA',
        signal: const CallSignal(type: CallSignalType.iceCandidate, callId: 'stale'),
        activeRemotePeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        sessionCallId: 'c1',
        sessionActive: true,
      ),
      isFalse,
    );
    expect(
      acceptInboundCallSignal(
        from: 'ORBIT-AAAAAAAAAAAAAAAA',
        signal: hangup,
        activeRemotePeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        sessionCallId: 'c1',
        sessionActive: true,
      ),
      isTrue,
    );
    expect(
      acceptInboundCallSignal(
        from: 'ORBIT-CCCCCCCCCCCCCCCC',
        signal: const CallSignal(
          type: CallSignalType.offer,
          callId: 'c-new',
          sdp: _realSdp,
        ),
        activeRemotePeerId: null,
        sessionCallId: null,
        sessionActive: false,
      ),
      isTrue,
    );
  });
}
