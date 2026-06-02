// Canonical relay registration blob — Dart side. The GOLDEN string here is
// byte-identical to the Node golden in relay-server/test/register-blob.test.js.
// If the two ever diverge, signatures stop verifying — these paired golden
// tests are the guardrail that keeps the client and server builders in lockstep.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/relay_auth.dart';

void main() {
  // Same inputs + expected bytes as the Node test.
  const peer = 'ORBIT-ABCDEF';
  const nonce = 'Tm9uY2VWYWx1ZQ==';
  const ts = 1700000000000;
  const relay = 'relay-xyz';
  const golden = 'orbits-relay-register-v1\n'
      'peer:ORBIT-ABCDEF\n'
      'nonce:Tm9uY2VWYWx1ZQ==\n'
      'ts:1700000000000\n'
      'relay:relay-xyz';

  test('canonical register blob matches the frozen golden string', () {
    expect(
      buildRelayRegisterBlob(peer: peer, nonce: nonce, ts: ts, relay: relay),
      golden,
    );
  });

  test('blob bytes are UTF-8 of the golden, 5 lines, no trailing newline', () {
    final bytes = buildRelayRegisterBlobBytes(
        peer: peer, nonce: nonce, ts: ts, relay: relay);
    expect(bytes, equals(utf8.encode(golden)));
    final s = utf8.decode(bytes);
    expect(s.split('\n'), hasLength(5));
    expect(s.endsWith('\n'), isFalse);
    expect(s.split('\n').first, 'orbits-relay-register-v1');
  });
}
