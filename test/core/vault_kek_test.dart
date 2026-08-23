// Vault KEK wrap/unwrap behaviour, including the long-term-secret helpers
// added for audit C2 (identity / prekey privates at rest) and the UTF-8 fix
// for wrapping Strings (audit L8).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';

Uint8List _key32() =>
    Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 1) & 0xff));

void main() {
  setUp(clearVaultKek);
  tearDown(clearVaultKek);

  group('wrapBytes / unwrapBytes', () {
    test('round-trips bytes under a KEK', () async {
      await setVaultKek(_key32());
      final pt = Uint8List.fromList([1, 2, 3, 250, 0, 99]);
      final wrapped = await wrapBytes(pt);
      expect(wrapped, isA<String>());
      expect(isWrapped(wrapped), isTrue);
      final back = await unwrapBytes(wrapped);
      expect(back, equals(pt));
    });

    test('passes plaintext through unchanged when no KEK', () async {
      final pt = Uint8List.fromList([9, 8, 7]);
      final out = await wrapBytes(pt);
      expect(identical(out, pt), isTrue);
      expect(isWrapped(out), isFalse);
    });

    test('wrapping a String round-trips as UTF-8, not UTF-16 (L8)', () async {
      await setVaultKek(_key32());
      const s = 'привет 😀 mixed-ascii';
      final wrapped = await wrapBytes(s);
      final back = await unwrapBytes(wrapped);
      expect(back, isA<Uint8List>());
      expect(utf8.decode(back as List<int>), equals(s));
    });
  });

  group('wrapSecret / unwrapSecret (C2)', () {
    test('wrapSecret refuses to write plaintext when locked', () async {
      expect(hasVaultKek(), isFalse);
      expect(() => wrapSecret([1, 2, 3]), throwsStateError);
    });

    test('wrapSecret + unwrapSecret round-trips under a KEK', () async {
      await setVaultKek(_key32());
      final secret = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final wrapped = await wrapSecret(secret);
      expect(isWrapped(wrapped), isTrue);
      final back = await unwrapSecret(wrapped);
      expect(back, equals(secret));
    });

    test('unwrapSecret tolerates a legacy plaintext byte field', () async {
      await setVaultKek(_key32());
      final legacy = Uint8List.fromList([5, 6, 7, 8]);
      // A row written before C2 stores raw bytes, not a wrapped string.
      final back = await unwrapSecret(legacy);
      expect(back, equals(legacy));
    });

    test('unwrapSecret of a wrapped value fails once the vault locks',
        () async {
      await setVaultKek(_key32());
      final wrapped = await wrapSecret([1, 2, 3, 4]);
      clearVaultKek();
      expect(() => unwrapSecret(wrapped), throwsStateError);
    });
  });

  group('sync blob cipher (L3)', () {
    final plain = Uint8List.fromList(utf8.encode('{"msg":"привет 😀","n":7}'));

    test('round-trips an encrypted blob under the KEK', () async {
      await setVaultKek(_key32());
      final enc = wrapBlobSync(plain);
      expect(isBlobWrapped(enc), isTrue);
      expect(enc, isNot(equals(plain))); // actually encrypted
      final dec = unwrapBlobSync(enc);
      expect(dec, equals(plain));
    });

    test('wrapBlobSync throws when locked (no plaintext fallback, S-1 / S-2)',
        () {
      expect(hasVaultKek(), isFalse);
      expect(() => wrapBlobSync(plain), throwsStateError);
    });

    test('unwrapBlobSync passes a legacy plaintext blob through unchanged',
        () async {
      await setVaultKek(_key32());
      // A pre-L3 row is raw JSON bytes — no frame magic — so it must survive.
      final out = unwrapBlobSync(plain);
      expect(out, equals(plain));
    });

    test('decrypting an encrypted blob throws once the vault locks', () async {
      await setVaultKek(_key32());
      final enc = wrapBlobSync(plain);
      clearVaultKek();
      expect(() => unwrapBlobSync(enc), throwsStateError);
    });

    test('a tampered blob fails authentication', () async {
      await setVaultKek(_key32());
      final enc = wrapBlobSync(plain);
      enc[enc.length - 1] ^= 0x01; // flip a ciphertext/tag byte
      expect(() => unwrapBlobSync(enc), throwsA(anything));
    });

    test('a different KEK cannot decrypt', () async {
      await setVaultKek(_key32());
      final enc = wrapBlobSync(plain);
      clearVaultKek();
      await setVaultKek(
        Uint8List.fromList(List<int>.generate(32, (i) => 255 - i)),
      );
      expect(() => unwrapBlobSync(enc), throwsA(anything));
    });
  });
}
