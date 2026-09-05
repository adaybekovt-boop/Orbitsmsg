import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/calls/call_media_peer.dart';
import 'package:orbits_flutter/calls/hyperswarm_signaling.dart';

void main() {
  test('call signals round-trip without PeerJS types', () {
    const offer = CallSignal(
      type: CallSignalType.offer,
      callId: 'c1',
      sdp: 'v=0',
    );
    final again = CallSignal.fromJson(offer.toJson());
    expect(again.type, CallSignalType.offer);
    expect(again.sdp, 'v=0');
    expect(again.toJson().containsKey('OFFER'), isFalse);
  });

  test('native session exchanges offer, ICE, answer, hangup', () async {
    final seen = <CallSignal>[];
    final pc = FakeCallMediaPeer(peerName: 'alice');
    final session = NativeCallSession(
      send: (s) async => seen.add(s),
      createPeer: () async => pc,
    );
    await session.startOutgoing(callId: 'c1', localStream: 'stream');
    await session.addIce({'candidate': '1.1.1.1'});
    await session.applyRemote(
      const CallSignal(type: CallSignalType.answer, callId: 'c1', sdp: 'ans'),
    );
    expect(session.remoteSdp, 'ans');
    await session.hangup();
    expect(
      seen.map((s) => s.type),
      containsAll([
        CallSignalType.offer,
        CallSignalType.iceCandidate,
        CallSignalType.hangup,
      ]),
    );
    expect(session.closed, isTrue);
    expect(pc.closed, isTrue);
  });
}
