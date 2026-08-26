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
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' as pc;

import 'base64_helpers.dart';

const String _wrapPrefix = 'orb-wrap-v1:';

final _aes = AesGcm.with256bits();
final _blobRng = Random.secure();

SecretKey? _kek;

/// Raw 32-byte KEK kept alongside [_kek] so the synchronous blob cipher
/// ([wrapBlobSync] / [unwrapBlobSync]) can run without an async extract — the
/// `cryptography` AES-GCM is async, which doesn't fit Drift's synchronous
/// `.watch().map` row decoders (audit L3).
Uint8List? _kekRaw;

/// Install the KEK from raw bytes (typically scrypt dk). Must be ≥32 bytes;
/// only the first 32 are kept.
Future<void> setVaultKek(List<int> rawBytes) async {
  if (rawBytes.length < 32) {
    throw ArgumentError('vault: KEK must be at least 32 bytes');
  }
  final raw = Uint8List.fromList(rawBytes.sublist(0, 32));
  _kek = SecretKey(raw);
  _kekRaw = raw;
}

void clearVaultKek() {
  _kek = null;
  _kekRaw = null;
}

bool hasVaultKek() => _kek != null;

/// The raw 32-byte KEK currently in RAM, or null when locked. Used ONLY by the
/// biometric auto-unlock service to hand the freshly-derived KEK to the OS
/// secure keystore (mobile) right after a successful password unlock. Returns a
/// defensive copy. The bytes never leave the process except into the OS
/// keychain/keystore — never SharedPreferences, never disk, never logs.
Uint8List? currentVaultKekBytes() =>
    _kekRaw == null ? null : Uint8List.fromList(_kekRaw!);

bool isWrapped(Object? value) =>
    value is String && value.startsWith(_wrapPrefix);

// ─────────────────────────────────────────────────────────────
// Synchronous blob cipher (audit L3 — at-rest message/peer content)
// ─────────────────────────────────────────────────────────────
//
// AES-256-GCM via pointycastle (pure Dart, synchronous) so it can run inside
// Drift's synchronous row decoders. Frame: magic 'OB1' (3) | nonce (12) |
// ciphertext+tag. The magic lets reads distinguish an encrypted blob from a
// legacy plaintext JSON row (which always starts with '{' / '['), so existing
// data keeps decoding and migrates lazily on the next write.

const List<int> _blobMagic = [0x4F, 0x42, 0x31]; // 'OB1'
const int _blobNonceLen = 12;
const int _blobHeaderLen = 3 + _blobNonceLen; // magic + nonce

/// True if [data] carries the encrypted-blob frame (vs. legacy plaintext).
bool isBlobWrapped(List<int> data) =>
    data.length >= _blobHeaderLen &&
    data[0] == _blobMagic[0] &&
    data[1] == _blobMagic[1] &&
    data[2] == _blobMagic[2];

Uint8List _gcm({
  required bool encrypt,
  required Uint8List key,
  required Uint8List nonce,
  required Uint8List input,
}) {
  final cipher = pc.GCMBlockCipher(pc.AESEngine())
    ..init(
      encrypt,
      pc.AEADParameters(pc.KeyParameter(key), 128, nonce, Uint8List(0)),
    );
  return cipher.process(input);
}

/// Encrypt a storage blob under the KEK. Throws [StateError] when the vault
/// is locked — callers must not fall back to plaintext (S-1 / S-2).
Uint8List wrapBlobSync(List<int> plaintext) {
  final key = _kekRaw;
  if (key == null) {
    throw StateError(
      'vault: refusing to persist a content blob while locked (no KEK)',
    );
  }
  final nonce = Uint8List(_blobNonceLen);
  for (var i = 0; i < _blobNonceLen; i++) {
    nonce[i] = _blobRng.nextInt(256);
  }
  final ct = _gcm(
    encrypt: true,
    key: key,
    nonce: nonce,
    input: Uint8List.fromList(plaintext),
  );
  final out = Uint8List(_blobHeaderLen + ct.length);
  out.setRange(0, 3, _blobMagic);
  out.setRange(3, _blobHeaderLen, nonce);
  out.setRange(_blobHeaderLen, out.length, ct);
  return out;
}

/// Inverse of [wrapBlobSync]. A non-framed (legacy plaintext) blob is returned
/// unchanged so old rows keep decoding. Throws [StateError] if the blob is
/// encrypted but the vault is locked.
Uint8List unwrapBlobSync(List<int> stored) {
  if (!isBlobWrapped(stored)) {
    return stored is Uint8List ? stored : Uint8List.fromList(stored);
  }
  final key = _kekRaw;
  if (key == null) {
    throw StateError('vault: locked — cannot decrypt blob');
  }
  final nonce = Uint8List.fromList(stored.sublist(3, _blobHeaderLen));
  final ct = Uint8List.fromList(stored.sublist(_blobHeaderLen));
  return _gcm(encrypt: false, key: key, nonce: nonce, input: ct);
}

/// Wrap plaintext bytes under the in-memory KEK. Throws [StateError] when
/// the vault is locked — same fail-closed contract as [wrapBlobSync] /
/// [wrapSecret]. `null` input stays `null`.
Future<Object?> wrapBytes(Object? plaintext) async {
  if (plaintext == null) return plaintext;
  final key = _kek;
  if (key == null) {
    throw StateError(
      'vault: refusing to wrap bytes while locked (no KEK)',
    );
  }
  final List<int> bytes = plaintext is List<int>
      ? plaintext
      // utf8 (not codeUnits/UTF-16) so a wrapped String round-trips through
      // utf8.decode on the unwrap side and stays ASCII/Unicode-safe (audit L8).
      : plaintext is String
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

/// Wrap long-term private-key material for at-rest storage. Unlike
/// [wrapBytes], this **refuses** to fall back to plaintext: identity / prekey
/// scalars must never touch disk unencrypted (audit C2), so a missing KEK is a
/// hard error rather than a silent passthrough. Always returns the
/// `orb-wrap-v1:` string form.
Future<String> wrapSecret(List<int> plaintext) async {
  if (_kek == null) {
    throw StateError(
      'vault: refusing to persist a long-term secret while locked (no KEK)',
    );
  }
  final wrapped = await wrapBytes(plaintext);
  return wrapped as String;
}

/// Unwrap a value produced by [wrapSecret], tolerating a legacy plaintext
/// byte field (rows written before secret-at-rest wrapping landed — see
/// migration note in identity_key / prekey_store). Returns raw bytes either
/// way; throws on anything that is neither wrapped nor a byte buffer.
Future<Uint8List> unwrapSecret(Object? value) async {
  final out = await unwrapBytes(value);
  if (out is Uint8List) return out;
  if (out is List<int>) return Uint8List.fromList(out);
  throw StateError('vault: unwrapSecret expected bytes, got ${out.runtimeType}');
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
