// SQLCipher key derivation — pure Dart (web-safe so `database.dart` can import
// it on every target), even though the derived key is only used natively.
//
// HKDF-SHA256 (RFC 5869) with the fixed salt `'orbits-sqlite-key'` turns 32
// bytes of key material into the 64-hex-char key Drift hands to
// `PRAGMA key`. The salt domain-separates this from every other use of the
// same key material so the DB key can't be confused with a message/blob key.

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Derive the 64-hex-char SQLCipher key from 32 bytes of [keyMaterial].
String deriveSqlcipherKeyHex(List<int> keyMaterial) {
  final salt = utf8.encode('orbits-sqlite-key');
  final derived = _hkdfSha256(ikm: keyMaterial, salt: salt, length: 32);
  return derived.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Minimal HKDF-SHA256: extract + expand. [length] ≤ 32 ⇒ a single expand
/// block, which is all a 32-byte DB key needs.
List<int> _hkdfSha256({
  required List<int> ikm,
  required List<int> salt,
  required int length,
  List<int> info = const <int>[],
}) {
  final prk = Hmac(sha256, salt).convert(ikm).bytes;
  final out = <int>[];
  var block = <int>[];
  var counter = 1;
  while (out.length < length) {
    block = Hmac(sha256, prk).convert([...block, ...info, counter]).bytes;
    out.addAll(block);
    counter++;
  }
  return out.sublist(0, length);
}
