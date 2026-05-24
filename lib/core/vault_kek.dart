// Port of src/core/vaultKek.js — in-memory Key-Encryption-Key wrap/unwrap.
//
// The KEK is derived from the user's password via scrypt (see scrypt_kdf.dart)
// and held only in RAM for the duration of the unlocked session. It is never
// persisted. On logout / autolock / wipe the KEK is cleared.
//
// Consumers use [wrapBytes] / [unwrapBytes] to encrypt byte fields written to
// local storage (ratchet root key, chain keys, skipped message keys…) so an
// attacker with raw storage access cannot recover chat keys without the
// password. The wire format must stay byte-compatible with the JS build:
//   "orb-wrap-v1:<b64 iv(12)>:<b64 ct+tag(n+16)>"

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'base64_helpers.dart';

const String _wrapPrefix = 'orb-wrap-v1:';

final _aes = AesGcm.with256bits();

SecretKey? _kek;

/// Install the KEK from raw bytes (typically scrypt dk). Must be ≥32 bytes;
/// only the first 32 are kept.
Future<void> setVaultKek(List<int> rawBytes) async {
  if (rawBytes.length < 32) {
    throw ArgumentError('vault: KEK must be at least 32 bytes');
  }
  _kek = SecretKey(rawBytes.sublist(0, 32));
}

void clearVaultKek() {
  _kek = null;
}

bool hasVaultKek() => _kek != null;

bool isWrapped(Object? value) =>
    value is String && value.startsWith(_wrapPrefix);

/// Wrap plaintext bytes under the in-memory KEK. Returns the original input
/// unchanged when the KEK is not set (matches JS fallback so unlocked callers
/// can shovel data through wrapBytes without branching).
Future<Object?> wrapBytes(Object? plaintext) async {
  final key = _kek;
  if (key == null || plaintext == null) return plaintext;
  final List<int> bytes = plaintext is List<int>
      ? plaintext
      : plaintext is String
          // UTF-8, not codeUnits — code units can exceed a byte for non-Latin1
          // text and corrupt the ciphertext. (No current caller passes a
          // String; this keeps the defensive path byte-correct.)
          ? utf8.encode(plaintext)
          : (throw ArgumentError('vault: wrapBytes expects bytes'));
  final iv = _aes.newNonce();
  final box = await _aes.encrypt(bytes, secretKey: key, nonce: iv);
  final ctPlusTag = Uint8List(box.cipherText.length + box.mac.bytes.length)
    ..setRange(0, box.cipherText.length, box.cipherText)
    ..setRange(
      box.cipherText.length,
      box.cipherText.length + box.mac.bytes.length,
      box.mac.bytes,
    );
  return '$_wrapPrefix${bytesToBase64(Uint8List.fromList(iv))}:${bytesToBase64(ctPlusTag)}';
}

/// Unwrap a wrapped blob back to bytes. Passes non-wrapped values through
/// unchanged (mirrors JS — lets callers idempotently unwrap even when the
/// field is already plaintext during migration windows).
Future<Object?> unwrapBytes(Object? value) async {
  if (!isWrapped(value)) return value;
  final key = _kek;
  if (key == null) {
    throw StateError('vault: locked (no KEK)');
  }
  final rest = (value as String).substring(_wrapPrefix.length);
  final sep = rest.indexOf(':');
  if (sep < 0) {
    throw const FormatException('vault: malformed wrapped blob');
  }
  final iv = base64ToBytes(rest.substring(0, sep));
  final ctPlusTag = base64ToBytes(rest.substring(sep + 1));
  if (ctPlusTag.length < 16) {
    throw const FormatException('vault: wrapped ciphertext too short');
  }
  final ctLen = ctPlusTag.length - 16;
  final ct = ctPlusTag.sublist(0, ctLen);
  final mac = Mac(ctPlusTag.sublist(ctLen));
  final box = SecretBox(ct, nonce: iv, mac: mac);
  final pt = await _aes.decrypt(box, secretKey: key);
  return Uint8List.fromList(pt);
}
