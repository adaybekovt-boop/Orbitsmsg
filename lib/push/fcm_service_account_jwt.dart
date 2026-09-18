// Google FCM HTTP v1 service-account JWT (RS256). Not identity-signing-v1,
// not the Hyperswarm Noise key, not a ratchet scalar, and not the APNs
// P-256 provider key. Built so tests can prove the token shape;
// PushSender still refuses to send while kLiveFcmGateway is false.
// Never POSTs to the OAuth token URI. The JWT-bearer form lives in
// fcm_oauth_token_request.dart and is also never sent.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

/// Google OAuth token endpoint. Documented only — this library does not
/// exchange the JWT for an access token.
const String kFcmOauthTokenUri = 'https://oauth2.googleapis.com/token';

const String kFcmMessagingScope =
    'https://www.googleapis.com/auth/firebase.messaging';

/// Service-account fields from Google JSON (`client_email` + PKCS#8
/// `private_key`). Never an identity key or a device token.
class FcmServiceAccountKey {
  const FcmServiceAccountKey({
    required this.clientEmail,
    required this.privateKeyPem,
    this.privateKeyId = '',
  });

  final String clientEmail;
  final String privateKeyPem;
  final String privateKeyId;

  bool get isWellFormed =>
      clientEmail.isNotEmpty &&
      clientEmail.contains('@') &&
      clientEmail.length <= 256 &&
      !clientEmail.contains('://') &&
      !privateKeyId.contains('://') &&
      privateKeyPem.contains('BEGIN PRIVATE KEY') &&
      !privateKeyPem.contains('BEGIN EC PRIVATE KEY');
}

String? buildFcmServiceAccountJwt(
  FcmServiceAccountKey key, {
  int? iatSeconds,
}) {
  if (!key.isWellFormed) return null;
  final rsa = parseFcmPkcs8Pem(key.privateKeyPem);
  if (rsa == null) return null;
  final iat = iatSeconds ?? DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  final header = <String, String>{'alg': 'RS256', 'typ': 'JWT'};
  if (key.privateKeyId.isNotEmpty) header['kid'] = key.privateKeyId;
  final claims = <String, Object?>{
    'iss': key.clientEmail,
    'scope': kFcmMessagingScope,
    'aud': kFcmOauthTokenUri,
    'iat': iat,
    'exp': iat + 3600,
  };
  final signingInput =
      '${_b64url(utf8.encode(jsonEncode(header)))}.${_b64url(utf8.encode(jsonEncode(claims)))}';
  final sig = _signRs256(rsa, utf8.encode(signingInput));
  if (sig == null) return null;
  return '$signingInput.${_b64url(sig)}';
}

/// Verify an FCM service-account JWT against the matching RSA public
/// modulus. Tests only. Production send stays off.
bool verifyFcmServiceAccountJwt({
  required String jwt,
  required List<int> modulus,
  required List<int> publicExponent,
  required String clientEmail,
  String privateKeyId = '',
}) {
  final parts = jwt.split('.');
  if (parts.length != 3) return false;
  try {
    final header =
        jsonDecode(utf8.decode(_b64urlDecode(parts[0]))) as Map<String, Object?>;
    final claims =
        jsonDecode(utf8.decode(_b64urlDecode(parts[1]))) as Map<String, Object?>;
    if (header['alg'] != 'RS256') return false;
    if (header['typ'] != 'JWT') return false;
    if (privateKeyId.isNotEmpty && header['kid'] != privateKeyId) return false;
    if (claims['iss'] != clientEmail) return false;
    if (claims['aud'] != kFcmOauthTokenUri) return false;
    if (claims['scope'] != kFcmMessagingScope) return false;
    if (claims['iat'] is! num || claims['exp'] is! num) return false;
    if (claims.containsKey('peerId') ||
        claims.containsKey('sub') ||
        claims.containsKey('opaqueWakeToken') ||
        claims.containsKey('text') ||
        claims.containsKey('rootKey')) {
      return false;
    }
    final pub = pc.RSAPublicKey(
      _bytesToBigInt(modulus),
      _bytesToBigInt(publicExponent),
    );
    final verifier = pc.RSASigner(pc.SHA256Digest(), '0609608648016503040201')
      ..init(false, pc.PublicKeyParameter<pc.RSAPublicKey>(pub));
    return verifier.verifySignature(
      Uint8List.fromList(utf8.encode('${parts[0]}.${parts[1]}')),
      pc.RSASignature(_b64urlDecode(parts[2])),
    );
  } catch (_) {
    return false;
  }
}

pc.RSAPrivateKey? parseFcmPkcs8Pem(String pem) {
  try {
    final der = _pemToDer(pem, 'PRIVATE KEY');
    if (der == null) return null;
    return _parsePkcs8Rsa(der);
  } catch (_) {
    return null;
  }
}

/// Encode a generated RSA private key as PKCS#8 PEM (Google JSON shape).
/// Tests mint keys this way; production reads Google-issued PEM.
String encodeFcmPkcs8Pem(pc.RSAPrivateKey key) {
  final pkcs1 = _encodePkcs1(key);
  final alg = _derTlv(
    0x30,
    [
      ..._derTlv(0x06, const <int>[
        0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
      ]),
      ..._derTlv(0x05, const <int>[]),
    ],
  );
  final pkcs8 = _derTlv(
    0x30,
    [
      ..._derInteger(BigInt.zero),
      ...alg,
      ..._derTlv(0x04, pkcs1),
    ],
  );
  final b64 = base64Encode(pkcs8);
  final lines = <String>['-----BEGIN PRIVATE KEY-----'];
  for (var i = 0; i < b64.length; i += 64) {
    lines.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
  }
  lines.add('-----END PRIVATE KEY-----');
  return lines.join('\n');
}

Uint8List? _signRs256(pc.RSAPrivateKey key, List<int> data) {
  try {
    final signer = pc.RSASigner(pc.SHA256Digest(), '0609608648016503040201')
      ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(key));
    final sig = signer.generateSignature(Uint8List.fromList(data));
    return sig.bytes;
  } catch (_) {
    return null;
  }
}

pc.RSAPrivateKey _parsePkcs8Rsa(Uint8List der) {
  final outer = _DerReader(der);
  final seq = outer.expect(0x30);
  final body = _DerReader(seq);
  body.integer(); // version
  body.expect(0x30); // AlgorithmIdentifier
  final pkcs1 = body.expect(0x04);
  return _parsePkcs1Rsa(pkcs1);
}

pc.RSAPrivateKey _parsePkcs1Rsa(Uint8List der) {
  final outer = _DerReader(der);
  final seq = outer.expect(0x30);
  final body = _DerReader(seq);
  body.integer(); // version
  final n = body.integer();
  body.integer(); // e
  final d = body.integer();
  final p = body.integer();
  final q = body.integer();
  return pc.RSAPrivateKey(n, d, p, q);
}

Uint8List _encodePkcs1(pc.RSAPrivateKey key) {
  final n = key.modulus!;
  final d = key.privateExponent!;
  final p = key.p!;
  final q = key.q!;
  final e = key.publicExponent ?? BigInt.from(65537);
  final dP = d % (p - BigInt.one);
  final dQ = d % (q - BigInt.one);
  final qInv = q.modInverse(p);
  return _derTlv(0x30, [
    ..._derInteger(BigInt.zero),
    ..._derInteger(n),
    ..._derInteger(e),
    ..._derInteger(d),
    ..._derInteger(p),
    ..._derInteger(q),
    ..._derInteger(dP),
    ..._derInteger(dQ),
    ..._derInteger(qInv),
  ]);
}

Uint8List? _pemToDer(String pem, String label) {
  final begin = '-----BEGIN $label-----';
  final end = '-----END $label-----';
  final start = pem.indexOf(begin);
  final stop = pem.indexOf(end);
  if (start < 0 || stop < 0 || stop <= start) return null;
  final b64 = pem
      .substring(start + begin.length, stop)
      .replaceAll(RegExp(r'\s'), '');
  if (b64.isEmpty) return null;
  return Uint8List.fromList(base64Decode(b64));
}

class _DerReader {
  _DerReader(this.buf);
  final Uint8List buf;
  var i = 0;

  Uint8List expect(int tag) {
    final (t, v) = next();
    if (t != tag) throw const FormatException('unexpected der tag');
    return v;
  }

  BigInt integer() => _bytesToBigInt(expect(0x02));

  (int, Uint8List) next() {
    if (i >= buf.length) throw const FormatException('der eof');
    final tag = buf[i++];
    if (i >= buf.length) throw const FormatException('der eof');
    var len = buf[i++];
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      if (n == 0 || n > 4 || i + n > buf.length) {
        throw const FormatException('der length');
      }
      len = 0;
      for (var k = 0; k < n; k++) {
        len = (len << 8) | buf[i++];
      }
    }
    if (i + len > buf.length) throw const FormatException('der truncated');
    final value = buf.sublist(i, i + len);
    i += len;
    return (tag, value);
  }
}

Uint8List _derTlv(int tag, List<int> body) {
  return Uint8List.fromList(<int>[tag, ..._derLength(body.length), ...body]);
}

Uint8List _derInteger(BigInt value) {
  var bytes = _bigIntToMinimal(value);
  if (bytes.isEmpty) bytes = Uint8List.fromList(const [0]);
  if (bytes[0] & 0x80 != 0) {
    bytes = Uint8List.fromList(<int>[0, ...bytes]);
  }
  return _derTlv(0x02, bytes);
}

List<int> _derLength(int n) {
  if (n < 0x80) return <int>[n];
  final out = <int>[];
  var v = n;
  while (v > 0) {
    out.insert(0, v & 0xff);
    v >>= 8;
  }
  return <int>[0x80 | out.length, ...out];
}

Uint8List _bigIntToMinimal(BigInt value) {
  if (value == BigInt.zero) return Uint8List.fromList(const [0]);
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
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

/// Test helper: mint an RSA pair the FCM JWT tests can PEM-encode.
pc.AsymmetricKeyPair<pc.PublicKey, pc.PrivateKey> generateFcmRsaKeyForTests({
  int bitLength = 1024,
}) {
  final rnd = pc.FortunaRandom();
  final seed = Uint8List(32);
  final dart = Random.secure();
  for (var i = 0; i < seed.length; i++) {
    seed[i] = dart.nextInt(256);
  }
  rnd.seed(pc.KeyParameter(seed));
  final gen = pc.RSAKeyGenerator()
    ..init(
      pc.ParametersWithRandom(
        pc.RSAKeyGeneratorParameters(BigInt.from(65537), bitLength, 12),
        rnd,
      ),
    );
  return gen.generateKeyPair();
}

Uint8List fcmModulusBytes(pc.RSAPublicKey pub) =>
    _bigIntToMinimal(pub.modulus!);

Uint8List fcmPublicExponentBytes(pc.RSAPublicKey pub) =>
    _bigIntToMinimal(pub.publicExponent!);
