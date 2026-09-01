import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/push/opaque_wake.dart';

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

  test('protocolVersion from APNs/FCM extras may be a string', () {
    expect(opaqueWakeProtocolVersion(1), 1);
    expect(opaqueWakeProtocolVersion('1'), 1);
    expect(opaqueWakeProtocolVersion(' 2 '), 2);
    expect(opaqueWakeProtocolVersion(2.0), 2);
    expect(opaqueWakeProtocolVersion(null), 0);
    expect(opaqueWakeProtocolVersion('nope'), 0);
  });
}
