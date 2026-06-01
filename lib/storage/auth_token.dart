// Port of `src/core/authToken.js`.
//
// HMAC-SHA256-signed JSON tokens for internal app auth. Not interoperable
// with OAuth / JWT — the body is a raw JSON map and the signing key is
// generated on first use and persisted via `idb_store.dart` (v9 db `kv`
// table, so it survives restart but stays device-local).
//
// Wire shape (byte-compatible with the JS build):
//
//   <base64url(json body)> . <base64url(hmac-sha256(body))>
//
// The body carries at least `{iat, exp, v: 1}` plus any caller payload;
// [verifyAuthToken] rejects tokens whose signature fails *or* whose
// `exp` is in the past.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'idb_store.dart';

const String _keyId = 'auth_hmac_key_v1';
const String _tokenId = 'auth_token_v1';

final _hmac = Hmac.sha256();
final _rng = Random.secure();

// ─── Base64URL helpers ──────────────────────────────────────────────
//
// Kept separate from `core/base64_helpers.dart` which is plain base64 —
// auth tokens want the URL-safe alphabet without padding so they can be
// passed through HTTP headers / URLs without escaping.

String _toBase64Url(List<int> bytes) {
  final b64 = base64Encode(bytes);
  return b64
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replaceAll(RegExp(r'=+$'), '');
}

Uint8List _fromBase64Url(String b64u) {
  var s = b64u.replaceAll('-', '+').replaceAll('_', '/');
  final pad = s.length % 4;
  if (pad != 0) s += '=' * (4 - pad);
  return base64Decode(s);
}

// ─── HMAC key lifecycle ─────────────────────────────────────────────

/// Fetch the persistent 32-byte HMAC key, generating + saving a fresh one
/// on first call. The key itself is stored base64url-encoded in `kv` so it
/// survives restarts without hitting any of the typed Drift tables.
Future<SecretKey> _getOrCreateHmacKey() async {
  final existing = await idbGetString(_keyId);
  if (existing != null && existing.isNotEmpty) {
    final raw = _fromBase64Url(existing);
    if (raw.length == 32) {
      return SecretKey(raw);
    }
    // Corrupt entry — fall through to regeneration.
  }
  final raw = Uint8List(32);
  for (var i = 0; i < raw.length; i++) {
    raw[i] = _rng.nextInt(256);
  }
  await idbSetString(_keyId, _toBase64Url(raw));
  return SecretKey(raw);
}

Future<Uint8List> _sign(SecretKey key, List<int> data) async {
  final mac = await _hmac.calculateMac(data, secretKey: key);
  return Uint8List.fromList(mac.bytes);
}

Future<bool> _verify(SecretKey key, List<int> sig, List<int> data) async {
  final mac = await _hmac.calculateMac(data, secretKey: key);
  if (mac.bytes.length != sig.length) return false;
  var diff = 0;
  for (var i = 0; i < sig.length; i++) {
    diff |= mac.bytes[i] ^ sig[i];
  }
  return diff == 0;
}

// ─── Public API ─────────────────────────────────────────────────────

/// Mint a new auth token wrapping [payload]. `ttlMs` is clamped to
/// ≥60 000 ms — matches JS which silently bumps shorter TTLs.
///
/// Side-effect: the token is also persisted via `idbSet(_tokenId)` so
/// [readAuthToken] can fetch it on next launch without the caller holding
/// it in-memory.
Future<String> issueAuthToken(
  Map<String, Object?> payload, {
  required int ttlMs,
}) async {
  final key = await _getOrCreateHmacKey();
  final now = DateTime.now().millisecondsSinceEpoch;
  final body = <String, Object?>{
    ...payload,
    'iat': now,
    'exp': now + (ttlMs < 60000 ? 60000 : ttlMs),
    'v': 1,
  };
  final bodyBytes = utf8.encode(jsonEncode(body));
  final sigBytes = await _sign(key, bodyBytes);
  final token = '${_toBase64Url(bodyBytes)}.${_toBase64Url(sigBytes)}';
  await idbSetString(_tokenId, token);
  return token;
}

/// Return the last-persisted token, or null if none.
Future<String?> readAuthToken() => idbGetString(_tokenId);

/// Wipe the persisted token. Call on logout.
Future<void> clearAuthToken() => idbDel(_tokenId);

/// Validate a token. Returns the decoded body on success, or null on any
/// failure (format error, bad signature, expired). [_verify] compares the two
/// MACs byte-by-byte without an early exit on mismatch; it does return early
/// when the lengths differ, but both are fixed 32-byte HMAC-SHA256 outputs so
/// that branch leaks nothing useful to an attacker (audit L2).
Future<Map<String, Object?>?> verifyAuthToken(String? token) async {
  if (token == null || token.isEmpty) return null;
  final parts = token.split('.');
  if (parts.length != 2) return null;

  final Uint8List bodyBytes;
  final Uint8List sigBytes;
  try {
    bodyBytes = _fromBase64Url(parts[0]);
    sigBytes = _fromBase64Url(parts[1]);
  } catch (_) {
    return null;
  }

  final key = await _getOrCreateHmacKey();
  final ok = await _verify(key, sigBytes, bodyBytes);
  if (!ok) return null;

  Map<String, Object?> body;
  try {
    final decoded = jsonDecode(utf8.decode(bodyBytes));
    if (decoded is! Map) return null;
    body = Map<String, Object?>.from(decoded);
  } catch (_) {
    return null;
  }

  final exp = body['exp'];
  if (exp is! num) return null;
  if (exp.toInt() < DateTime.now().millisecondsSinceEpoch) return null;
  return body;
}
