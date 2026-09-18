import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/push/opaque_wake.dart';
import 'package:orbits_flutter/push/push_gateway.dart';
import 'package:orbits_flutter/transport/layers.dart';

void main() {
  test('wake payload is opaque', () {
    const wake = OpaqueWake(
      opaqueWakeToken: 'tok',
      collapseId: 'c1',
      protocolVersion: 1,
    );
    expect(OpaqueWake.isSafe(wake.toJson()), isTrue);
    expect(
      OpaqueWake.isSafe({
        ...wake.toJson(),
        'peerId': 'ORBIT-AA',
      }),
      isFalse,
    );
    expect(
      OpaqueWake.isSafe({
        ...wake.toJson(),
        'text': 'hi',
      }),
      isFalse,
    );
  });

  test('wake payload rejects Hypercore and mailbox secrets', () {
    const wake = OpaqueWake(
      opaqueWakeToken: 'tok',
      collapseId: 'c1',
      protocolVersion: 1,
    );
    final safe = wake.toJson();
    expect(OpaqueWake.isSafe(safe), isTrue);
    expect(OpaqueWake.isSafe({...safe, 'fileKey': 'x'}), isFalse);
    expect(OpaqueWake.isSafe({...safe, 'fileKeyB64': 'eA=='}), isFalse);
    expect(OpaqueWake.isSafe({...safe, 'kek': 'k'}), isFalse);
    expect(OpaqueWake.isSafe({...safe, 'rootKey': 'r'}), isFalse);
    expect(OpaqueWake.isSafe({...safe, 'discoverySecret': 'd'}), isFalse);
  });

  test('forbiddenKeys covers UX metadata and kForbiddenReplicationFields', () {
    expect(
      OpaqueWake.forbiddenKeys.containsAll(kForbiddenReplicationFields),
      isTrue,
    );
    expect(OpaqueWake.forbiddenKeys.contains('title'), isTrue);
    expect(OpaqueWake.forbiddenKeys.contains('senderName'), isTrue);
    expect(OpaqueWake.forbiddenKeys.contains('displayName'), isTrue);
    expect(OpaqueWake.forbiddenKeys.contains('peerId'), isTrue);
    expect(OpaqueWake.forbiddenKeys.contains('conversationId'), isTrue);
    expect(OpaqueWake.forbiddenKeys.contains('attachment'), isTrue);
    expect(OpaqueWake.forbiddenKeys.contains('mime'), isTrue);
    expect(OpaqueWake.forbiddenKeys.contains('fileName'), isTrue);
    expect(OpaqueWake.forbiddenKeys.contains('text'), isTrue);
    expect(OpaqueWake.forbiddenKeys.contains('body'), isTrue);
  });

  test('isSafe rejects forbidden keys nested under a child map', () {
    const wake = OpaqueWake(
      opaqueWakeToken: 'tok',
      collapseId: 'c1',
      protocolVersion: 1,
    );
    final safe = wake.toJson();
    expect(
      OpaqueWake.isSafe({
        ...safe,
        'extra': {'fileKey': 'x'},
      }),
      isFalse,
    );
    expect(
      OpaqueWake.isSafe({
        ...safe,
        'extra': {'text': 'hi'},
      }),
      isFalse,
    );
    expect(
      OpaqueWake.isSafe({
        ...safe,
        'extra': {'discoverySecret': 'd'},
      }),
      isFalse,
    );
    expect(
      OpaqueWake.isSafe({
        ...safe,
        'extra': {'peerId': 'ORBIT-AA'},
      }),
      isFalse,
    );
    expect(
      OpaqueWake.isSafe({
        ...safe,
        'ciphertext': <int>[1, 2, 3],
      }),
      isTrue,
    );
  });

  test('isSafe rejects URL and secret-fragment opaqueWakeToken values', () {
    const wake = OpaqueWake(
      opaqueWakeToken: 'tok',
      collapseId: 'c1',
      protocolVersion: 1,
    );
    final base = wake.toJson();
    expect(OpaqueWake.isSafe(base), isTrue);
    expect(
      OpaqueWake.isSafe({...base, 'opaqueWakeToken': 'https://evil.example/x'}),
      isFalse,
    );
    expect(
      OpaqueWake.isSafe({...base, 'opaqueWakeToken': 'peerId-fragment'}),
      isFalse,
    );
    expect(
      OpaqueWake.isSafe({...base, 'opaqueWakeToken': 'has-fileKey'}),
      isFalse,
    );
    expect(
      OpaqueWake.isSafe({...base, 'opaqueWakeToken': 'rootKey'}),
      isFalse,
    );
    expect(
      OpaqueWake.isSafe({...base, 'opaqueWakeToken': 'discoverySecret-1'}),
      isFalse,
    );
    expect(
      OpaqueWake.isSafe({...base, 'opaqueWakeToken': ''}),
      isFalse,
    );
  });

  test('live APNs and FCM gateways stay off', () {
    expect(kLiveApnsGateway, isFalse);
    expect(kLiveFcmGateway, isFalse);
  });

  test('protocolVersion from APNs/FCM extras may be a string', () {
    expect(opaqueWakeProtocolVersion(1), 1);
    expect(opaqueWakeProtocolVersion('1'), 1);
    expect(opaqueWakeProtocolVersion(' 2 '), 2);
    expect(opaqueWakeProtocolVersion(2.0), 2);
    expect(opaqueWakeProtocolVersion(null), 0);
    expect(opaqueWakeProtocolVersion('nope'), 0);
  });
}
