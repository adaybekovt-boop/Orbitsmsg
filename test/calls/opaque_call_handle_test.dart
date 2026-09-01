import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/calls/opaque_call_handle.dart';

void main() {
  test('system call handle is not the peer id', () {
    const peer = 'ORBIT-AAAAAAAAAAAAAAAA';
    final handle = opaqueCallHandle(peer);
    expect(handle, isNot(contains('ORBIT')));
    expect(handle, isNot(equals(peer)));
    expect(handle.length, 16);
    expect(opaqueCallHandle(peer), handle);
    expect(kSystemCallDisplayName, 'Orbits');
  });
}
