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
}
