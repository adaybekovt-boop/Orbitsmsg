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

  test(
    'Alice phone / Alice tablet / Bob keep isolated RatchetState',
    () async {
      final phone = await _session(seed: 1);
      final tablet = await _session(seed: 80);

      expect(
        bytesToBase64(phone.alice.rootKey),
        isNot(bytesToBase64(tablet.alice.rootKey)),
      );
      expect(
        bytesToBase64(phone.bob.rootKey),
        isNot(bytesToBase64(tablet.bob.rootKey)),
      );
      expect(
        bytesToBase64(phone.alice.rootKey),
        isNot(bytesToBase64(phone.bob.rootKey)),
      );
      expect(identical(phone.alice, tablet.alice), isFalse);
      expect(identical(phone.alice.rootKey, tablet.alice.rootKey), isFalse);

      final fromPhone = await ratchetEncrypt(phone.alice, 'phone-to-bob');
      expect(
        utf8.decode(await ratchetDecrypt(phone.bob, fromPhone)),
        'phone-to-bob',
      );

      await expectLater(
        ratchetDecrypt(tablet.bob, fromPhone),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      await expectLater(
        ratchetDecrypt(tablet.alice, fromPhone),
        throwsA(anything),
      );

      final fromTablet = await ratchetEncrypt(tablet.alice, 'tablet-to-bob');
      expect(
        utf8.decode(await ratchetDecrypt(tablet.bob, fromTablet)),
        'tablet-to-bob',
      );
      await expectLater(
        ratchetDecrypt(phone.bob, fromTablet),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      expect(
        bytesToBase64(phone.alice.rootKey),
        isNot(bytesToBase64(tablet.alice.rootKey)),
      );
    },
  );
}

class _Session {
  _Session(this.alice, this.bob);
  final RatchetState alice;
  final RatchetState bob;
}

Future<_Session> _session({required int seed}) async {
  final shared = Uint8List.fromList(List<int>.generate(32, (i) => seed + i));
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
  return _Session(alice, bob);
}
