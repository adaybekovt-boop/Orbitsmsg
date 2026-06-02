// Double Ratchet transactional-decrypt rollback (audit P0 item 1).
//
// `ratchetDecrypt` now snapshots the whole ratchet state, mutates while
// deriving keys, and rolls EVERYTHING back if the authenticated decrypt (or any
// step) throws — so a corrupted / tampered / bad-MAC packet can never advance
// or destroy the session.
//
// NOTE: we can't run a live ratchet round-trip in `flutter test` because the
// pure-Dart `cryptography` backend's P-256 `newKeyPair` is unimplemented in the
// VM (the reason the repo only has fixture-based crypto tests). So we test the
// rollback BOOKKEEPING directly via the (visibleForTesting) snapshot: it must
// restore every mutable field, including the DH keypair reference and the
// skipped-key map — a missed field would let a bad packet corrupt the session.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/double_ratchet.dart';

Uint8List _b(int fill) => Uint8List.fromList(List<int>.filled(4, fill));
EcKeyPairData _kp(int seed) => EcKeyPairData(
      d: List<int>.filled(32, seed),
      x: List<int>.filled(32, seed + 1),
      y: List<int>.filled(32, seed + 2),
      type: KeyPairType.p256,
    );

void main() {
  test('snapshot.restore reverts EVERY mutable field after a failed decrypt',
      () {
    final originalKp = _kp(1);
    final state = RatchetState(
      rootKey: _b(1),
      dhKeyPair: originalKp,
      dhPubSpki: _b(2),
      sendCk: _b(3),
      recvCk: _b(4),
      remoteDhPub: _b(5),
      ns: 1,
      nr: 2,
      pn: 3,
      skipped: {'k0': _b(9)},
    );
    final snap = RatchetStateSnapshot(state);

    // Simulate the mutations a DH-ratchet step + chain advance would make
    // before an authenticated decrypt fails.
    state.rootKey = _b(91);
    state.sendCk = _b(92); // a forged-DH packet would replace the SEND chain
    state.recvCk = _b(93);
    state.dhKeyPair = _kp(50); // …and regenerate the keypair
    state.dhPubSpki = _b(94);
    state.remoteDhPub = _b(95);
    state.ns = 50;
    state.nr = 60;
    state.pn = 70;
    state.skipped
      ..clear()
      ..['k1'] = _b(88);

    snap.restore(state);

    expect(state.rootKey, _b(1));
    expect(state.sendCk, _b(3), reason: 'send chain must be restored');
    expect(state.recvCk, _b(4));
    expect(identical(state.dhKeyPair, originalKp), isTrue,
        reason: 'the ORIGINAL DH keypair reference must be restored');
    expect(state.dhPubSpki, _b(2));
    expect(state.remoteDhPub, _b(5));
    expect(state.ns, 1);
    expect(state.nr, 2);
    expect(state.pn, 3);
    expect(state.skipped.keys.toList(), ['k0'],
        reason: 'skipped-key map membership must be restored');
    expect(state.skipped['k0'], _b(9));
  });

  test('restore handles a null send/recv chain (Bob pre-first-receive)', () {
    final state = RatchetState(
      rootKey: _b(1),
      dhKeyPair: _kp(1),
      dhPubSpki: _b(2),
      // sendCk / recvCk null — Bob before his first DH step.
    );
    final snap = RatchetStateSnapshot(state);
    state.sendCk = _b(7);
    state.recvCk = _b(8);
    snap.restore(state);
    expect(state.sendCk, isNull);
    expect(state.recvCk, isNull);
  });
}
