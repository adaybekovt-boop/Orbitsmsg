// Apple APNs provider JWT (ES256). Not identity-signing-v1, not the
// Hyperswarm Noise key, and not a ratchet scalar. Built so tests can
// prove the token shape; PushSender still refuses to send while
// kLiveApnsGateway is false.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

/// Apple Developer team id + key id + P-256 private scalar from a .p8.
/// Never an identity key or a device token.
class ApnsProviderKey {
  const ApnsProviderKey({
    required this.teamId,
    required this.keyId,
    required this.privateKeyD,
  });

  final String teamId;
  final String keyId;

  /// 32-byte P-256 private scalar. Not identity-signing-v1.
  final List<int> privateKeyD;

  bool get isWellFormed =>
      teamId.isNotEmpty &&
      teamId.length <= 16 &&
      !teamId.contains('://') &&
      keyId.isNotEmpty &&
      keyId.length <= 16 &&
      !keyId.contains('://') &&
      privateKeyD.length == 32;
}

String? buildApnsProviderJwt(
  ApnsProviderKey key, {
  int? iatSeconds,
}) {
  if (!key.isWellFormed) return null;
  final iat = iatSeconds ?? DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  final header = jsonEncode(<String, String>{'alg': 'ES256', 'kid': key.keyId});
  final claims = jsonEncode(<String, Object?>{'iss': key.teamId, 'iat': iat});
  final signingInput =
      '${_b64url(utf8.encode(header))}.${_b64url(utf8.encode(claims))}';
  final sig = _signEs256(key.privateKeyD, utf8.encode(signingInput));
  if (sig == null) return null;
  return '$signingInput.${_b64url(sig)}';
}

/// Verify an APNs provider JWT against the matching P-256 public point.
/// Tests only. Production send stays off.
bool verifyApnsProviderJwt({
  required String jwt,
  required List<int> publicX,
  required List<int> publicY,
  required String teamId,
  required String keyId,
}) {
  final parts = jwt.split('.');
  if (parts.length != 3) return false;
  try {
    final header =
        jsonDecode(utf8.decode(_b64urlDecode(parts[0]))) as Map<String, Object?>;
    final claims =
        jsonDecode(utf8.decode(_b64urlDecode(parts[1]))) as Map<String, Object?>;
    if (header['alg'] != 'ES256') return false;
    if (header['kid'] != keyId) return false;
    if (header.length != 2) return false;
    if (claims['iss'] != teamId) return false;
    if (claims['iat'] is! num) return false;
    if (claims.containsKey('peerId') ||
        claims.containsKey('sub') ||
        claims.containsKey('opaqueWakeToken') ||
        claims.containsKey('text')) {
      return false;
    }
    if (claims.length != 2) return false;
    final sig = _b64urlDecode(parts[2]);
    if (sig.length != 64) return false;
    final params = pc.ECDomainParameters('prime256v1');
    final q = params.curve.createPoint(
      _bytesToBigInt(publicX),
      _bytesToBigInt(publicY),
    );
    final pub = pc.ECPublicKey(q, params);
    final verifier = pc.ECDSASigner(pc.SHA256Digest())
      ..init(false, pc.PublicKeyParameter<pc.ECPublicKey>(pub));
    final r = _bytesToBigInt(sig.sublist(0, 32));
    final s = _bytesToBigInt(sig.sublist(32));
    return verifier.verifySignature(
      Uint8List.fromList(utf8.encode('${parts[0]}.${parts[1]}')),
      pc.ECSignature(r, s),
    );
  } catch (_) {
    return false;
  }
}

Uint8List? _signEs256(List<int> d, List<int> data) {
  if (d.length != 32) return null;
  try {
    final params = pc.ECDomainParameters('prime256v1');
    final priv = pc.ECPrivateKey(_bytesToBigInt(d), params);
    final signer = pc.ECDSASigner(pc.SHA256Digest())
      ..init(
        true,
        pc.ParametersWithRandom(
          pc.PrivateKeyParameter<pc.ECPrivateKey>(priv),
          _fortuna(),
        ),
      );
    final sig =
        signer.generateSignature(Uint8List.fromList(data)) as pc.ECSignature;
    final out = Uint8List(64);
    out.setAll(0, _bigIntToBytes(sig.r, 32));
    out.setAll(32, _bigIntToBytes(sig.s, 32));
    return out;
  } catch (_) {
    return null;
  }
}

pc.FortunaRandom _fortuna() {
  final rnd = pc.FortunaRandom();
  final seed = Uint8List(32);
  final dart = Random.secure();
  for (var i = 0; i < seed.length; i++) {
    seed[i] = dart.nextInt(256);
  }
  rnd.seed(pc.KeyParameter(seed));
  return rnd;
}

String _b64url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List _b64urlDecode(String s) {
  var out = s.replaceAll('-', '+').replaceAll('_', '/');
  final pad = (4 - out.length % 4) % 4;
  out = out.padRight(out.length + pad, '=');
  return Uint8List.fromList(base64Decode(out));
}

BigInt _bytesToBigInt(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

Uint8List _bigIntToBytes(BigInt value, int length) {
  final out = Uint8List(length);
  var n = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (n & BigInt.from(0xff)).toInt();
    n = n >> 8;
  }
  return out;
}
