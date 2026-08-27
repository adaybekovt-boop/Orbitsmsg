// R01 — concurrent Double Ratchet ops must not lose send-chain state
// or reuse a message key.
//
// Two encrypt() calls launched with Future.wait both read sendCk before
// either finishes await kdfCk. Without a session queue they derive the
// same message key and/or clobber ns. Decrypt's clone→adopt can also
// overwrite a send-chain advance that landed between clone and adopt.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/double_ratchet.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  installPointyCastleEcdh();

  group('R01 ratchet session queue', () {
    test('two concurrent encrypt() calls use distinct n and message keys',
        () async {
      final pair = await _handshake();
      final startNs = pair.alice.ns;
      final startSendCk = List<int>.from(pair.alice.sendCk!);

      final envelopes = await Future.wait<RatchetEnvelope>([
        ratchetEncrypt(pair.alice, 'alpha'),
        ratchetEncrypt(pair.alice, 'beta'),
      ]);

      expect(pair.alice.ns, startNs + 2,
          reason: 'both encrypts must advance ns exactly once each');
      expect(pair.alice.sendCk, isNot(equals(startSendCk)),
          reason: 'sendCk must move past both chain steps');

      final ns = envelopes.map((e) => decodeHeader(e.headerB64).n).toList();
      expect(ns.toSet(), {startNs, startNs + 1},
          reason: 'headers must carry distinct monotonic n');

      final plaintexts = <String>{};
      for (final env in envelopes) {
        plaintexts.add(utf8.decode(await ratchetDecrypt(pair.bob, env)));
      }
      expect(plaintexts, {'alpha', 'beta'});
    });

    test('concurrent encrypt + decrypt does not roll back sendCk/ns', () async {
      // Finish the DH so a later in-chain decrypt will not reset Alice.ns.
      final pair = await _established();
      final bobEnv = await ratchetEncrypt(pair.bob, 'from-bob');
      final startNs = pair.alice.ns;
      final startSendCk = List<int>.from(pair.alice.sendCk!);

      late RatchetEnvelope aliceEnv;
      late Uint8List bobPlain;
      await Future.wait<void>([
        () async {
          aliceEnv = await ratchetEncrypt(pair.alice, 'from-alice');
        }(),
        () async {
          bobPlain = await ratchetDecrypt(pair.alice, bobEnv);
        }(),
      ]);

      expect(utf8.decode(bobPlain), 'from-bob');
      expect(pair.alice.ns, startNs + 1);
      expect(pair.alice.sendCk, isNot(equals(startSendCk)));
      expect(
        utf8.decode(await ratchetDecrypt(pair.bob, aliceEnv)),
        'from-alice',
      );
    });

    test('two concurrent decrypt() calls both succeed without key reuse',
        () async {
      final pair = await _established();
      final startNr = pair.bob.nr;
      final envA = await ratchetEncrypt(pair.alice, 'one');
      final envB = await ratchetEncrypt(pair.alice, 'two');

      final plains = await Future.wait<Uint8List>([
        ratchetDecrypt(pair.bob, envA),
        ratchetDecrypt(pair.bob, envB),
      ]);
      expect(
        plains.map(utf8.decode).toSet(),
        {'one', 'two'},
      );
      // A DH step on the first of the pair may reset Nr; the invariant is
      // "both plaintexts recovered, neither key is reusable".
      expect(pair.bob.nr, greaterThanOrEqualTo(startNr));
      await expectLater(
        ratchetDecrypt(pair.bob, envA),
        throwsA(anything),
      );
      await expectLater(
        ratchetDecrypt(pair.bob, envB),
        throwsA(anything),
      );
    });
  });
}

class _Pair {
  _Pair(this.alice, this.bob);
  final RatchetState alice;
  final RatchetState bob;
}

Future<_Pair> _freshPair() async {
  final shared = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
  final bobDh = await generateDhKeyPair();
  final bobSpki = await exportSpkiBytes(bobDh);
  final alice = await ratchetInitAlice(
    sharedSecret: shared,
    remoteDhPubSpki: bobSpki,
  );
  final bob = await ratchetInitBob(
    sharedSecret: shared,
    dhKeyPair: bobDh,
    dhPubSpki: bobSpki,
  );
  return _Pair(alice, bob);
}

Future<_Pair> _handshake() async {
  final pair = await _freshPair();
  final env = await ratchetEncrypt(pair.alice, 'handshake');
  expect(utf8.decode(await ratchetDecrypt(pair.bob, env)), 'handshake');
  return pair;
}

/// Both send/recv chains live; a further in-order decrypt will not DH-step.
Future<_Pair> _established() async {
  final pair = await _handshake();
  final reply = await ratchetEncrypt(pair.bob, 'reply');
  expect(utf8.decode(await ratchetDecrypt(pair.alice, reply)), 'reply');
  return pair;
}
