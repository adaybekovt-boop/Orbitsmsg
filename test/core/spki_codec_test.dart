// SPKI parse/build, including the invalid-curve point check added for M2.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/spki_codec.dart';

Uint8List _hex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

// NIST P-256 base point G — a known on-curve point. (We hardcode rather than
// generate a key because the pure-Dart `cryptography` ECDH backend used under
// `flutter test` doesn't implement key generation — which is itself why the
// M2 on-curve check matters: the backend won't reject off-curve points for us.)
final Uint8List _gx =
    _hex('6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296');
final Uint8List _gy =
    _hex('4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5');

void main() {
  group('parseP256Spki', () {
    test('accepts and round-trips a genuine on-curve P-256 point', () {
      final spki = buildP256Spki(x: _gx, y: _gy);
      final point = parseP256Spki(spki);
      expect(point.x, equals(_gx));
      expect(point.y, equals(_gy));
      expect(buildP256Spki(x: point.x, y: point.y), equals(spki));
    });

    test('rejects a blob of the wrong length', () {
      expect(() => parseP256Spki(Uint8List(90)), throwsFormatException);
    });

    test('rejects a corrupted (off-curve) point (M2)', () {
      final spki = buildP256Spki(x: _gx, y: _gy);
      // Prefix stays valid; flip a byte inside Y (offset 59..90) so (x,y) is
      // almost certainly no longer on the curve.
      final tampered = Uint8List.fromList(spki);
      tampered[70] ^= 0x01;
      expect(() => parseP256Spki(tampered), throwsFormatException);
    });

    test('rejects the point at infinity (all-zero x,y)', () {
      final spki = Uint8List(91)..setRange(0, p256SpkiPrefix.length, p256SpkiPrefix);
      // x and y remain all-zero — not a valid affine point.
      expect(() => parseP256Spki(spki), throwsFormatException);
    });
  });
}
