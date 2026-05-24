// Port of src/core/scryptKdf.js — password-based KDF used to unlock the vault.
//
// The JS side uses `scrypt-js` (pure-JS). The Dart `cryptography` package
// does not ship scrypt, so we route through `pointycastle`'s
// ScryptKeyDerivator, which is a direct implementation of RFC 7914.
//
// Password record format (must stay byte-compatible with JS):
//
// v1 (legacy, INSECURE): stored the raw scrypt-derived key (`dkB64`) in
//   localStorage. Anyone who read storage could decrypt the vault directly.
//   We still verify these records so existing users can log in, then the
//   caller should re-derive and rewrite them in the v2 format.
//
// v2: stores `verifierB64` = HMAC-SHA256(dk, "orbits-scrypt-verifier-v2").
//   Verifying reveals one HMAC image — useless without brute-forcing scrypt.
//
// keyMaterial is always `"${username}:${password}:ORBITS_P2P"` — do not
// change without bumping the record version, or every user gets locked out.
//
// IMPORTANT: scrypt is CPU-heavy (~400–800 ms on a mobile device at N=2^16).
// Callers should run it via `Isolate.run` so the UI thread stays responsive.
// This module stays synchronous-looking by returning a Future; the actual
// heavy lifting happens inside `_scrypt` which is safe to dispatch to an
// isolate by the caller.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' as pc;

import 'base64_helpers.dart';

const String verifierTag = 'orbits-scrypt-verifier-v2';
const String _keyMaterialSuffix = 'ORBITS_P2P';

/// Default scrypt cost parameters — must match scryptKdf.js defaults so newly
/// derived records are byte-identical to the JS build.
const int scryptDefaultN = 65536; // 2^16
const int scryptDefaultR = 8;
const int scryptDefaultP = 1;
const int scryptDefaultDkLen = 32;

final _secureRandom = Random.secure();

Uint8List _randomBytes(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _secureRandom.nextInt(256);
  }
  return out;
}

Uint8List _keyMaterial(String username, String password) {
  final u = username.trim();
  return Uint8List.fromList(utf8.encode('$u:$password:$_keyMaterialSuffix'));
}

Future<Uint8List> _scrypt({
  required Uint8List password,
  required Uint8List salt,
  required int n,
  required int r,
  required int p,
  required int dkLen,
}) async {
  final derivator = pc.Scrypt()
    ..init(pc.ScryptParameters(n, r, p, dkLen, salt));
  return derivator.process(password);
}

Future<Uint8List> _computeVerifier(List<int> dk) async {
  final hmac = Hmac.sha256();
  final mac = await hmac.calculateMac(
    utf8.encode(verifierTag),
    secretKey: SecretKey(dk),
  );
  return Uint8List.fromList(mac.bytes);
}

bool _timingSafeEqualStr(String a, String b) {
  if (a.length != b.length) return false;
  var out = 0;
  for (var i = 0; i < a.length; i++) {
    out |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return out == 0;
}

/// Parameter overrides for [deriveScryptRecord]. All fields are optional and
/// fall back to the OWASP-aligned defaults when null.
class ScryptParams {
  const ScryptParams({this.n, this.r, this.p, this.dkLen});
  final int? n;
  final int? r;
  final int? p;
  final int? dkLen;
}

/// The stored verification record plus the in-memory derived key. Only
/// `algo / v / saltB64 / N / r / p / dkLen / verifierB64` should ever be
/// persisted — `dkBytes` is returned so the caller can seed the vault KEK
/// without running scrypt a second time.
class ScryptRecord {
  const ScryptRecord({
    required this.username,
    required this.saltB64,
    required this.n,
    required this.r,
    required this.p,
    required this.dkLen,
    required this.verifierB64,
    required this.dkBytes,
  });
  final String algo = 'scrypt';
  final int v = 2;

  /// The username folded into the key material at derivation time. Persisted
  /// so verification always reuses the *original* value even if the user later
  /// renames their profile — otherwise the re-derived key would diverge and
  /// lock the user out of their own vault.
  final String username;
  final String saltB64;
  final int n;
  final int r;
  final int p;
  final int dkLen;
  final String verifierB64;
  final Uint8List dkBytes;

  /// Persistable JSON matching the JS `deriveScryptRecord` output shape.
  Map<String, Object?> toJson() => {
        'algo': algo,
        'v': v,
        'kdfUsername': username,
        'saltB64': saltB64,
        'N': n,
        'r': r,
        'p': p,
        'dkLen': dkLen,
        'verifierB64': verifierB64,
      };
}

/// Derive a fresh scrypt record for [username] / [password]. Generates a new
/// 16-byte random salt. Caller is responsible for persisting everything
/// except `dkBytes`.
Future<ScryptRecord> deriveScryptRecord({
  required String username,
  required String password,
  ScryptParams? params,
}) async {
  final salt = _randomBytes(16);
  final n = max(8192, params?.n ?? scryptDefaultN);
  final r = max(8, params?.r ?? scryptDefaultR);
  final p = max(1, params?.p ?? scryptDefaultP);
  final dkLen = max(32, params?.dkLen ?? scryptDefaultDkLen);

  final dk = await _scrypt(
    password: _keyMaterial(username, password),
    salt: salt,
    n: n,
    r: r,
    p: p,
    dkLen: dkLen,
  );
  final verifier = await _computeVerifier(dk);
  return ScryptRecord(
    username: username.trim(),
    saltB64: bytesToBase64(salt),
    n: n,
    r: r,
    p: p,
    dkLen: dkLen,
    verifierB64: bytesToBase64(verifier),
    dkBytes: dk,
  );
}

/// Stored record as read back from disk / JSON. Accepts both v1 (`dkB64`)
/// and v2 (`verifierB64`) shapes so older users keep working.
class ScryptStoredRecord {
  const ScryptStoredRecord({
    required this.saltB64,
    required this.n,
    required this.r,
    required this.p,
    required this.dkLen,
    this.verifierB64,
    this.dkB64,
    this.kdfUsername,
  });

  final String saltB64;
  final int n;
  final int r;
  final int p;
  final int dkLen;
  final String? verifierB64;
  final String? dkB64;

  /// The username persisted at derivation time, if present. Records written
  /// before this field existed return null; callers fall back to the current
  /// profile name for those.
  final String? kdfUsername;

  static ScryptStoredRecord? fromJson(Map<String, Object?> json) {
    if (json['algo'] != 'scrypt') return null;
    final saltB64 = json['saltB64'];
    if (saltB64 is! String) return null;
    final n = (json['N'] as num?)?.toInt() ?? 0;
    final r = (json['r'] as num?)?.toInt() ?? 0;
    final p = (json['p'] as num?)?.toInt() ?? 0;
    final dkLen = (json['dkLen'] as num?)?.toInt() ?? 0;
    if (n == 0 || r == 0 || p == 0 || dkLen == 0) return null;
    return ScryptStoredRecord(
      saltB64: saltB64,
      n: n,
      r: r,
      p: p,
      dkLen: dkLen,
      verifierB64: json['verifierB64'] as String?,
      dkB64: json['dkB64'] as String?,
      kdfUsername: json['kdfUsername'] as String?,
    );
  }
}

/// Result of a verify — `ok` true means the password matched, and `dkBytes`
/// is the freshly re-derived KEK (null on failure). Callers should seed the
/// vault KEK from `dkBytes` without ever persisting it.
typedef ScryptVerifyResult = ({bool ok, Uint8List? dkBytes});

/// Verify a stored scrypt record against [username] / [password]. Mirrors
/// `verifyScryptRecordEx` — returns `{ok, dkBytes}` so v1 records can be
/// rewrapped immediately on a successful unlock.
Future<ScryptVerifyResult> verifyScryptRecordEx({
  required String username,
  required String password,
  required ScryptStoredRecord record,
}) async {
  final miss = (ok: false, dkBytes: null);
  final salt = base64ToBytes(record.saltB64);
  final dk = await _scrypt(
    password: _keyMaterial(username, password),
    salt: salt,
    n: record.n,
    r: record.r,
    p: record.p,
    dkLen: record.dkLen,
  );

  // v2 — preferred path.
  if (record.verifierB64 != null) {
    final verifier = await _computeVerifier(dk);
    final ok = _timingSafeEqualStr(bytesToBase64(verifier), record.verifierB64!);
    return ok ? (ok: true, dkBytes: dk) : miss;
  }

  // v1 legacy — record stored the raw dk.
  if (record.dkB64 != null) {
    final ok = _timingSafeEqualStr(bytesToBase64(dk), record.dkB64!);
    return ok ? (ok: true, dkBytes: dk) : miss;
  }

  return miss;
}

/// Convenience boolean wrapper matching `verifyScryptRecord`.
Future<bool> verifyScryptRecord({
  required String username,
  required String password,
  required ScryptStoredRecord record,
}) async {
  final result = await verifyScryptRecordEx(
    username: username,
    password: password,
    record: record,
  );
  return result.ok;
}
