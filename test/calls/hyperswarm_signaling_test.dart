import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

  test('legit ICE and media maps still parse', () {
    final ice = CallSignal.fromJson({
      'type': CallSignalType.iceCandidate.name,
      'callId': 'c1',
      'candidate': {'candidate': '1.1.1.1'},
    });
    expect(ice.type, CallSignalType.iceCandidate);
    expect(ice.candidate, {'candidate': '1.1.1.1'});

    const media = CallSignal(
      type: CallSignalType.mediaState,
      callId: 'c1',
      media: {'muted': true},
    );
    final again = CallSignal.fromJson(media.toJson());
    expect(again.type, CallSignalType.mediaState);
    expect(again.media, {'muted': true});
  });

  test('fromJson refuses nested fileKey in candidate', () {
    expect(
      () => CallSignal.fromJson({
        'type': CallSignalType.iceCandidate.name,
        'callId': 'c1',
        'candidate': {
          'candidate': '1.1.1.1',
          'extra': {'fileKey': 'x'},
        },
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('fromJson refuses kek in media', () {
    expect(
      () => CallSignal.fromJson({
        'type': CallSignalType.mediaState.name,
        'callId': 'c1',
        'media': {'muted': true, 'kek': 'x'},
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('native session exchanges offer, ICE, answer, hangup', () async {
    final seen = <CallSignal>[];
    final session = NativeCallSession(send: (s) async => seen.add(s));
    await session.startOutgoing(callId: 'c1', sdp: 'offer-sdp');
    await session.addIce({'candidate': '1.1.1.1'});
    session.applyRemote(
      const CallSignal(type: CallSignalType.answer, callId: 'c1', sdp: 'ans'),
    );
    expect(session.remoteSdp, 'ans');
    await session.hangup();
    expect(seen.map((s) => s.type), [
      CallSignalType.offer,
      CallSignalType.iceCandidate,
      CallSignalType.hangup,
    ]);
    expect(session.closed, isTrue);
  });

  test('sendCallSignal refuses unsafe toJson before transport.send', () {
    final src = File('lib/transport/dual_stack_bridge.dart').readAsStringSync();
    expect(src, contains('replicationValueIsSafe'));
    final method = src
        .split('Future<void> sendCallSignal')[1]
        .split('Future<bool> sendDrop')[0];
    expect(method, contains('replicationValueIsSafe'));
    expect(method, contains('signal.toJson()'));
    expect(
      method.indexOf('replicationValueIsSafe'),
      lessThan(method.indexOf('transport.send')),
    );
  });
}
