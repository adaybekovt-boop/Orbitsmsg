// Parse / build the 91-byte SubjectPublicKeyInfo blob that Web Crypto produces
// for an ECDH (or ECDSA) P-256 public key.
//
// Web Crypto's spki export is fully deterministic: a fixed 27-byte ASN.1
// prefix (SEQUENCE + AlgorithmIdentifier{id-ecPublicKey, prime256v1} +
// BIT STRING header + uncompressed-point marker 0x04) followed by exactly
// 32 bytes of X and 32 bytes of Y. See research/04_SPKI _bytes_layout.md for
// the full byte-by-byte walkthrough. Because the layout is nailed down by
// RFC 5280 + RFC 5480 + the W3C Web Crypto spec (which MUSTs the uncompressed
// point form and id-ecPublicKey OID), hard-coded offsets are safe — we just
// have to validate the prefix strictly so a malformed blob can't slip raw X/Y
// of a different curve past us (invalid-curve attacks).
//
// This replaces the earlier heuristic `lastIndexOf(0x04)` scan in x3dh.dart,
// which was fragile against any 0x04 byte that happened to appear in the DER
// parameters or the Y-coordinate itself.

import 'dart:typed_data';

/// Fixed ASN.1 DER prefix for `SubjectPublicKeyInfo { id-ecPublicKey,
/// prime256v1, BIT STRING containing uncompressed point }`. 27 bytes: 26 of
/// header (SEQUENCE, OIDs, BIT STRING, unused-bits) + the 0x04 point-format
/// marker. Bytes 27..58 are X, 59..90 are Y.
const List<int> p256SpkiPrefix = [
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86,
  0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
  0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
  0x42, 0x00, 0x04,
];

const int p256SpkiLength = 91;

/// Parsed X / Y coordinates, each exactly 32 bytes, big-endian.
typedef EcPoint = ({Uint8List x, Uint8List y});

/// Strict parse of a P-256 SPKI blob. Validates length and the full 27-byte
/// prefix — any deviation throws [FormatException] rather than returning
/// possibly-hostile coordinates.
EcPoint parseP256Spki(List<int> spki) {
  if (spki.length != p256SpkiLength) {
    throw FormatException(
      'spki: expected $p256SpkiLength bytes for P-256 SPKI, got ${spki.length}',
    );
  }
  for (var i = 0; i < p256SpkiPrefix.length; i++) {
    if (spki[i] != p256SpkiPrefix[i]) {
      throw FormatException(
        'spki: prefix mismatch at byte $i — not a P-256 ECDH/ECDSA SPKI blob',
      );
    }
  }
  final x = Uint8List.fromList(spki.sublist(27, 59));
  final y = Uint8List.fromList(spki.sublist(59, 91));
  // Invalid-curve defence (audit M2): a strict prefix only guarantees the
  // *encoding*, not that (X,Y) is a real point on P-256. The pure-Dart ECDH
  // backend isn't guaranteed to reject off-curve points, so feeding a crafted
  // point could leak the private scalar over a sequence of handshakes. Verify
  // the point satisfies the curve equation before anyone does DH with it.
  if (!_isOnCurveP256(x, y)) {
    throw const FormatException(
      'spki: point is not on the P-256 curve — possible invalid-curve attack',
    );
  }
  return (x: x, y: y);
}

// ── P-256 curve parameters (FIPS 186-4 / SEC2 prime256v1) ──
final BigInt _p256P = BigInt.parse(
    'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
    radix: 16);
final BigInt _p256B = BigInt.parse(
    '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
    radix: 16);

BigInt _bytesToBigInt(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

/// True iff (x,y) is an affine point on P-256: `y² ≡ x³ - 3x + b (mod p)`,
/// with both coordinates in `[0, p)`. Rejects the point at infinity (0,0).
bool _isOnCurveP256(List<int> xBytes, List<int> yBytes) {
  final x = _bytesToBigInt(xBytes);
  final y = _bytesToBigInt(yBytes);
  if (x >= _p256P || y >= _p256P) return false;
  if (x == BigInt.zero && y == BigInt.zero) return false;
  final lhs = (y * y) % _p256P;
  // a = p - 3, so a*x ≡ -3x (mod p). Keep everything non-negative.
  final rhs = (x * x % _p256P * x + (_p256P - BigInt.from(3)) * x + _p256B) %
      _p256P;
  return lhs == rhs;
}

/// Build a 91-byte P-256 SPKI blob from raw X / Y coordinates. Both must be
/// exactly 32 bytes (left-pad with zero upstream if your BigInt → bytes
/// helper may drop leading zero bytes).
Uint8List buildP256Spki({required List<int> x, required List<int> y}) {
  if (x.length != 32) {
    throw ArgumentError('spki: X must be 32 bytes, got ${x.length}');
  }
  if (y.length != 32) {
    throw ArgumentError('spki: Y must be 32 bytes, got ${y.length}');
  }
  final out = Uint8List(p256SpkiLength);
  out.setRange(0, p256SpkiPrefix.length, p256SpkiPrefix);
  out.setRange(27, 59, x);
  out.setRange(59, 91, y);
  return out;
}
