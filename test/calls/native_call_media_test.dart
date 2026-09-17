import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/calls/hyperswarm_signaling.dart';
import 'package:orbits_flutter/calls/native_call_media.dart';

void main() {
  test('ICE candidate JSON round-trips without PeerJS types', () {
    final json = iceCandidateToJson(
      candidate: 'candidate:1 1 UDP 1 127.0.0.1 9 typ host',
      sdpMid: '0',
      sdpMLineIndex: 0,
    );
    expect(json['candidate'], contains('127.0.0.1'));
    expect(json.containsKey('peerId'), isFalse);
    expect(isCompleteIceCandidate(json), isTrue);
    expect(isCompleteIceCandidate(const <String, Object?>{}), isFalse);
    final ice = rtcIceCandidateFromJson(json);
    expect(ice.candidate, json['candidate']);
    expect(ice.sdpMid, '0');
    expect(ice.sdpMLineIndex, 0);
  });

  test('NativeIceBuffer holds trickle ICE until remote description', () {
    final buf = NativeIceBuffer();
    expect(
      buf.ingest({'candidate': 'cand-a', 'sdpMid': '0'}),
      isEmpty,
    );
    expect(buf.pending, hasLength(1));
    expect(
      buf.ingest(const <String, Object?>{'candidate': ''}),
      isEmpty,
    );
    final flushed = buf.markRemoteDescriptionSet();
    expect(flushed, hasLength(1));
    expect(flushed.single['candidate'], 'cand-a');
    expect(buf.pending, isEmpty);
    expect(
      buf.ingest({'candidate': 'cand-b'}),
      [{'candidate': 'cand-b'}],
    );
  });

  test('native session still carries offer / ICE / hangup', () async {
    final seen = <CallSignal>[];
    final session = NativeCallSession(send: (s) async => seen.add(s));
    session.callId = 'c1';
    await session.addIce(
      iceCandidateToJson(candidate: 'cand', sdpMid: '0', sdpMLineIndex: 0),
    );
    expect(seen.single.type, CallSignalType.iceCandidate);
    expect(seen.single.callId, 'c1');
    expect(seen.single.candidate!['candidate'], 'cand');
  });
}
