// Transactional Double Ratchet decrypt.
//
// ratchetDecrypt used to mutate skipped keys / DH / Nr / recvCk *before*
// AES-GCM. A tampered ct/tag (or AAD) then burned skipped message keys and
// could commit a DH step, so the authentic envelope could never decrypt.
// These cases fail on that in-place commit.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/base64_helpers.dart';
import 'package:orbits_flutter/core/double_ratchet.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  // Must run before generateDhKeyPair / ratchetInit* first-touch Ecdh.p256().
  installPointyCastleEcdh();

  group('ratchetDecrypt transactional commit', () {
    test('Alice/Bob handshake plus reply round-trips', () async {
      final pair = await _freshPair();
      final env = await ratchetEncrypt(pair.alice, 'hello bob');
      expect(utf8.decode(await ratchetDecrypt(pair.bob, env)), 'hello bob');

      final reply = await ratchetEncrypt(pair.bob, 'hello alice');
      expect(
        utf8.decode(await ratchetDecrypt(pair.alice, reply)),
        'hello alice',
      );
    });

    test(
      'in-order after handshake: tampered ct leaves Nr/recvCk; original decrypts',
      () async {
        final pair = await _handshake();
        final env = await ratchetEncrypt(pair.alice, 'second');
        final before = _Snap.of(pair.bob);

        await expectLater(
          ratchetDecrypt(pair.bob, _flipLastCtByte(env)),
          throwsA(isA<SecretBoxAuthenticationError>()),
        );
        expect(_Snap.of(pair.bob), before);
        expect(utf8.decode(await ratchetDecrypt(pair.bob, env)), 'second');
      },
    );

    test('skipped path: tampered older message keeps the cached MK', () async {
      final pair = await _freshPair();
      final env0 = await ratchetEncrypt(pair.alice, 'zero');
      final env1 = await ratchetEncrypt(pair.alice, 'one');
      final env2 = await ratchetEncrypt(pair.alice, 'two');

      expect(utf8.decode(await ratchetDecrypt(pair.bob, env2)), 'two');
      expect(pair.bob.skipped.length, 2);

      final before = _Snap.of(pair.bob);
      await expectLater(
        ratchetDecrypt(pair.bob, _flipLastCtByte(env0)),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      expect(_Snap.of(pair.bob), before);
      expect(pair.bob.skipped.length, 2);

      expect(utf8.decode(await ratchetDecrypt(pair.bob, env0)), 'zero');
      expect(utf8.decode(await ratchetDecrypt(pair.bob, env1)), 'one');
    });

    test(
      'skip-forward without DH: tampered n=2 does not commit skipped n=1',
      () async {
        final pair = await _handshake();
        final env1 = await ratchetEncrypt(pair.alice, 'one');
        final env2 = await ratchetEncrypt(pair.alice, 'two');
        final before = _Snap.of(pair.bob);

        await expectLater(
          ratchetDecrypt(pair.bob, _flipLastCtByte(env2)),
          throwsA(isA<SecretBoxAuthenticationError>()),
        );
        expect(_Snap.of(pair.bob), before);
        expect(pair.bob.skipped, isEmpty);
        expect(pair.bob.nr, before.nr);

        expect(utf8.decode(await ratchetDecrypt(pair.bob, env1)), 'one');
        expect(utf8.decode(await ratchetDecrypt(pair.bob, env2)), 'two');
      },
    );

    test(
      'DH path: tampered first envelope does not commit Bob DH step',
      () async {
        final pair = await _freshPair();
        expect(pair.bob.remoteDhPub, isNull);
        expect(pair.bob.recvCk, isNull);
        expect(pair.bob.nr, 0);

        final env = await ratchetEncrypt(pair.alice, 'first');
        final before = _Snap.of(pair.bob);

        await expectLater(
          ratchetDecrypt(pair.bob, _flipLastCtByte(env)),
          throwsA(isA<SecretBoxAuthenticationError>()),
        );
        expect(_Snap.of(pair.bob), before);
        expect(pair.bob.remoteDhPub, isNull);
        expect(pair.bob.recvCk, isNull);
        expect(pair.bob.nr, 0);

        expect(utf8.decode(await ratchetDecrypt(pair.bob, env)), 'first');
        expect(pair.bob.remoteDhPub, isNotNull);
        expect(pair.bob.recvCk, isNotNull);
      },
    );

    test(
      'tampered header AAD leaves state unchanged; original decrypts',
      () async {
        final pair = await _handshake();
        final env = await ratchetEncrypt(pair.alice, 'aad');
        final before = _Snap.of(pair.bob);

        await expectLater(
          ratchetDecrypt(pair.bob, _tweakHeaderAad(env)),
          throwsA(isA<SecretBoxAuthenticationError>()),
        );
        expect(_Snap.of(pair.bob), before);
        expect(utf8.decode(await ratchetDecrypt(pair.bob, env)), 'aad');
      },
    );

    test('invalid headerB64 leaves state unchanged', () async {
      final pair = await _handshake();
      final env = await ratchetEncrypt(pair.alice, 'hdr');
      final before = _Snap.of(pair.bob);

      await expectLater(
        ratchetDecrypt(
          pair.bob,
          RatchetEnvelope(
            headerB64: 'not-valid-header!!!!',
            ivB64: env.ivB64,
            ctB64: env.ctB64,
          ),
        ),
        throwsA(anything),
      );
      expect(_Snap.of(pair.bob), before);
      expect(utf8.decode(await ratchetDecrypt(pair.bob, env)), 'hdr');
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

/// Alice's first message decrypted by Bob so both have live send/recv chains.
Future<_Pair> _handshake() async {
  final pair = await _freshPair();
  final env = await ratchetEncrypt(pair.alice, 'handshake');
  expect(utf8.decode(await ratchetDecrypt(pair.bob, env)), 'handshake');
  return pair;
}

RatchetEnvelope _flipLastCtByte(RatchetEnvelope env) {
  final ct = base64ToBytes(env.ctB64);
  ct[ct.length - 1] ^= 0x01;
  return RatchetEnvelope(
    headerB64: env.headerB64,
    ivB64: env.ivB64,
    ctB64: bytesToBase64(ct),
  );
}

/// Same decoded (dh, n, pn) so the receive path picks the same MK, but a
/// different headerB64 string so AES-GCM AAD fails.
RatchetEnvelope _tweakHeaderAad(RatchetEnvelope env) {
  final header = decodeHeader(env.headerB64);
  final obj = {
    'dh': bytesToBase64(header.dhPubSpki),
    'n': header.n,
    'pn': header.pn,
  };
  final spaced = jsonEncode(obj).replaceAll(':', ': ');
  return RatchetEnvelope(
    headerB64: bytesToBase64(Uint8List.fromList(utf8.encode(spaced))),
    ivB64: env.ivB64,
    ctB64: env.ctB64,
  );
}

class _Snap {
  _Snap({
    required this.rootKey,
    required this.sendCk,
    required this.recvCk,
    required this.dhPub,
    required this.remoteDh,
    required this.ns,
    required this.nr,
    required this.pn,
    required this.skipped,
  });

  factory _Snap.of(RatchetState s) {
    return _Snap(
      rootKey: bytesToBase64(s.rootKey),
      sendCk: s.sendCk == null ? null : bytesToBase64(s.sendCk!),
      recvCk: s.recvCk == null ? null : bytesToBase64(s.recvCk!),
      dhPub: bytesToBase64(s.dhPubSpki),
      remoteDh: s.remoteDhPub == null ? null : bytesToBase64(s.remoteDhPub!),
      ns: s.ns,
      nr: s.nr,
      pn: s.pn,
      skipped: {
        for (final e in s.skipped.entries) e.key: bytesToBase64(e.value),
      },
    );
  }

  final String rootKey;
  final String? sendCk;
  final String? recvCk;
  final String dhPub;
  final String? remoteDh;
  final int ns;
  final int nr;
  final int pn;
  final Map<String, String> skipped;

  @override
  bool operator ==(Object other) {
    if (other is! _Snap) return false;
    if (rootKey != other.rootKey ||
        sendCk != other.sendCk ||
        recvCk != other.recvCk ||
        dhPub != other.dhPub ||
        remoteDh != other.remoteDh ||
        ns != other.ns ||
        nr != other.nr ||
        pn != other.pn) {
      return false;
    }
    if (skipped.length != other.skipped.length) return false;
    for (final e in skipped.entries) {
      if (other.skipped[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(rootKey, recvCk, nr, skipped.length);

  @override
  String toString() =>
      'Snap(nr=$nr ns=$ns pn=$pn remoteDh=$remoteDh skipped=${skipped.length} '
      'recvCk=$recvCk sendCk=$sendCk)';
}
