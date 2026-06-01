// Port of src/core/crypto.js — vault-level KDF + AES-GCM for local storage.
//
// Mirrors the JS surface:
//   cryptoDerive(password, nickname, salt)   →  deriveVaultKey
//   cryptoEncrypt(obj) / cryptoDecrypt(str)  →  encryptJson / decryptJson
//   cryptoLock()                             →  lock
//   cryptoSha256Hex(str)                     →  sha256Hex
//   cryptoPbkdf2Bytes(password, salt, iters) →  pbkdf2Bytes
//
// KDF version semantics (must stay aligned with JS — see crypto.js:67-76):
//   v1 → 100k iters, salt = String(salt), base = password + nickname
//   v2 → 310k iters, salt = base64(saltB64), base = password
//   v3 → 600k iters, salt = base64(saltB64), base = password  (OWASP 2026)
//
// Ciphertext envelope:
//   "<base64(iv)>:<base64(ciphertext)>" — iv is 12 bytes, ciphertext is
//   AES-256-GCM with 16-byte tag appended (cryptography package default).

import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

import 'base64_helpers.dart';

class CryptoLocal {
  SecretKey? _vaultKey;

  final _aes = AesGcm.with256bits();
  final _pbkdf2v3 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 600000,
    bits: 256,
  );
  final _pbkdf2v2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 310000,
    bits: 256,
  );
  final _pbkdf2v1 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 100000,
    bits: 256,
  );

  bool get isUnlocked => _vaultKey != null;

  /// Derive and cache the vault key. Equivalent to the JS `cryptoDerive`.
  ///
  /// - [password] — user's master password
  /// - [nickname] — only used for v1 (legacy vaults)
  /// - [saltB64]  — base64 salt when available (v2+)
  /// - [saltFallback] — raw string salt, used only if [saltB64] is null (v1)
  /// - [iterations] — overrides the per-version default
  /// - [version]  — 1 / 2 / 3; defaults to 3 for new vaults
  Future<void> deriveVaultKey({
    required String password,
    String? nickname,
    String? saltB64,
    String? saltFallback,
    int? iterations,
    int version = 3,
  }) async {
    final Uint8List salt = saltB64 != null
        ? base64ToBytes(saltB64)
        : Uint8List.fromList(utf8.encode(saltFallback ?? ''));

    final String baseMaterial =
        version >= 2 ? password : '$password${nickname ?? ''}';

    final Pbkdf2 kdf;
    if (iterations != null) {
      kdf = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: 256,
      );
    } else {
      kdf = switch (version) {
        >= 3 => _pbkdf2v3,
        2 => _pbkdf2v2,
        _ => _pbkdf2v1,
      };
    }

    final derived = await kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(baseMaterial)),
      nonce: salt,
    );
    _vaultKey = derived;
  }

  void lock() => _vaultKey = null;

  /// JSON-encode and encrypt. Output format matches JS: "base64Iv:base64Ct".
  Future<String> encryptJson(Object? obj) async {
    final key = _requireKey();
    final plaintext = utf8.encode(jsonEncode(obj));
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
    );
    // JS packs tag inside ciphertext (Web Crypto does this automatically). We
    // mirror that layout so cross-platform blobs stay compatible.
    final combined = Uint8List(box.cipherText.length + box.mac.bytes.length)
      ..setRange(0, box.cipherText.length, box.cipherText)
      ..setRange(
          box.cipherText.length, box.cipherText.length + box.mac.bytes.length, box.mac.bytes);
    return '${bytesToBase64(Uint8List.fromList(nonce))}:${bytesToBase64(combined)}';
  }

  /// Decrypt the "base64Iv:base64Ct" envelope back into a parsed JSON value.
  Future<dynamic> decryptJson(String encStr) async {
    final key = _requireKey();
    final parts = encStr.split(':');
    if (parts.length != 2) {
      throw const FormatException('crypto: bad envelope');
    }
    final iv = base64ToBytes(parts[0]);
    final combined = base64ToBytes(parts[1]);
    if (combined.length < 16) {
      throw const FormatException('crypto: ciphertext too short');
    }
    final ctLen = combined.length - 16;
    final ct = combined.sublist(0, ctLen);
    final mac = Mac(combined.sublist(ctLen));
    final box = SecretBox(ct, nonce: iv, mac: mac);
    final plaintext = await _aes.decrypt(box, secretKey: key);
    return jsonDecode(utf8.decode(plaintext));
  }

  /// Best-effort batch decrypt — nulls out individual failures.
  Future<List<dynamic>> decryptBatch(List<String?> items) async {
    final out = <dynamic>[];
    for (final s in items) {
      if (s == null) {
        out.add(null);
        continue;
      }
      try {
        out.add(await decryptJson(s));
      } catch (_) {
        out.add(null);
      }
    }
    return out;
  }

  /// Hex-encoded SHA-256. Matches `cryptoSha256Hex` in JS.
  Future<String> sha256Hex(String str) async {
    final hash = await Sha256().hash(utf8.encode(str));
    return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Hex-encoded SHA-256 over arbitrary bytes. Matches `cryptoSha256Buffer`.
  Future<String> sha256HexBytes(List<int> bytes) async {
    final hash = await Sha256().hash(bytes);
    return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// PBKDF2-SHA256, returns base64 of derived bytes. Matches `cryptoPbkdf2Bytes`.
  Future<String> pbkdf2Bytes({
    required String password,
    required String saltB64,
    required int iterations,
    int lengthBytes = 32,
  }) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: lengthBytes * 8,
    );
    final key = await kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: base64ToBytes(saltB64),
    );
    final bytes = await key.extractBytes();
    return bytesToBase64(Uint8List.fromList(bytes));
  }

  SecretKey _requireKey() {
    final k = _vaultKey;
    if (k == null) throw StateError('crypto: vault locked (no key)');
    return k;
  }
}
