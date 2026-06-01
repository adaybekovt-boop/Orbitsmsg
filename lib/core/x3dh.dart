// Port of src/core/x3dh.js — Extended Triple Diffie-Hellman key agreement.
//
// Derives a shared secret SK between an initiator (Alice) and a responder
// (Bob) using Bob's published prekey bundle. Alice doesn't need Bob online —
// that's the whole point.
//
// Curve: ECDH P-256 (stays aligned with the React build; Signal's reference
// uses X25519 but the protocol is curve-agnostic as long as both sides agree).
//
// Four DHs (Alice side):
//   DH1 = DH(IK_a,  SPK_b)   — binds initiator identity to Bob's SPK
//   DH2 = DH(EK_a,  IK_b)    — binds ephemeral to Bob's identity
//   DH3 = DH(EK_a,  SPK_b)   — ephemeral ⇄ SPK
//   DH4 = DH(EK_a,  OPK_b)   — optional, if a one-time prekey was used
//
// SK = HKDF-SHA256(
//        salt = 32 zero bytes,
//        ikm  = F_PREFIX || DH1 || DH2 || DH3 [|| DH4],
//        info = "orbits-x3dh-v1")
// where F_PREFIX is 32 0xFF bytes (Signal's domain-separation prefix so this
// can't collide with an older X3DHv2-curve25519 derivation).
//
// The JS side exports `crypto.subtle.exportKey('spki', pub)` → 91 bytes. The
// Dart `cryptography` package wants raw X/Y on import, so we go through
// spki_codec to translate at the edges.

import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

import 'spki_codec.dart';

const String x3dhInfo = 'orbits-x3dh-v1';

/// Signal's 32-byte 0xFF prefix prepended to the IKM. Mirrors
/// src/core/x3dh.js:71.
final Uint8List _fPrefix = Uint8List.fromList(List.filled(32, 0xff));

/// HKDF salt — 32 null bytes. Must use a zero-filled array rather than an
/// empty list to avoid Dart cryptography bug #176 (empty salt throws on the
/// 2.7.x branch).
final Uint8List _x3dhSalt = Uint8List(32);

final _ecdh = Ecdh.p256(length: 32);

/// Raw ECDH P-256: produce 32-byte shared secret between our local private
/// key and the peer's public key given in SPKI bytes (the 91-byte blob the
/// JS side puts on the wire).
Future<Uint8List> dh({
  required EcKeyPair privateKey,
  required List<int> remotePubSpki,
}) async {
  final point = parseP256Spki(remotePubSpki);
  final remote = EcPublicKey(
    x: point.x,
    y: point.y,
    type: KeyPairType.p256,
  );
  final secret = await _ecdh.sharedSecretKey(
    keyPair: privateKey,
    remotePublicKey: remote,
  );
  final bytes = await secret.extractBytes();
  return Uint8List.fromList(bytes);
}

Uint8List _concat(List<List<int>> parts) {
  var len = 0;
  for (final p in parts) {
    len += p.length;
  }
  final out = Uint8List(len);
  var off = 0;
  for (final p in parts) {
    out.setRange(off, off + p.length, p);
    off += p.length;
  }
  return out;
}

/// HKDF-SHA256 with the fixed X3DH salt / info. Returns 32 bytes.
Future<Uint8List> hkdfX3dh(List<int> ikm) async {
  final kdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final derived = await kdf.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: _x3dhSalt,
    info: utf8.encode(x3dhInfo),
  );
  return Uint8List.fromList(await derived.extractBytes());
}

/// Derive SK from the four raw DH outputs. Pure function — same inputs always
/// produce the same 32-byte SK, which is what the cross-runtime round-trip
/// tests pin.
Future<Uint8List> deriveX3DHSecret({
  required List<int> dh1,
  required List<int> dh2,
  required List<int> dh3,
  List<int>? dh4,
}) async {
  final parts = <List<int>>[_fPrefix, dh1, dh2, dh3];
  if (dh4 != null) parts.add(dh4);
  return hkdfX3dh(_concat(parts));
}

/// Result of an X3DH run — the 32-byte session secret plus a flag the caller
/// uses to decide whether to include the OPK id in the outgoing hello.
typedef X3dhResult = ({Uint8List sk, bool usedOpk});

/// Initiator (Alice) side. Performs all DHs and derives SK.
Future<X3dhResult> initiatorX3DH({
  required EcKeyPair ikAPriv,
  required EcKeyPair ekAPriv,
  required List<int> ikBSpki,
  required List<int> spkBSpki,
  List<int>? opkBSpki,
}) async {
  final dh1 = await dh(privateKey: ikAPriv, remotePubSpki: spkBSpki);
  final dh2 = await dh(privateKey: ekAPriv, remotePubSpki: ikBSpki);
  final dh3 = await dh(privateKey: ekAPriv, remotePubSpki: spkBSpki);
  final dh4 =
      opkBSpki != null ? await dh(privateKey: ekAPriv, remotePubSpki: opkBSpki) : null;
  final sk = await deriveX3DHSecret(dh1: dh1, dh2: dh2, dh3: dh3, dh4: dh4);
  return (sk: sk, usedOpk: opkBSpki != null);
}

/// Responder (Bob) side. Mirrors the four DHs using his private halves — the
/// SK must match Alice's.
Future<X3dhResult> responderX3DH({
  required EcKeyPair spkBPriv,
  required EcKeyPair ikBPriv,
  EcKeyPair? opkBPriv,
  required List<int> ikASpki,
  required List<int> ekASpki,
}) async {
  final dh1 = await dh(privateKey: spkBPriv, remotePubSpki: ikASpki);
  final dh2 = await dh(privateKey: ikBPriv, remotePubSpki: ekASpki);
  final dh3 = await dh(privateKey: spkBPriv, remotePubSpki: ekASpki);
  final dh4 =
      opkBPriv != null ? await dh(privateKey: opkBPriv, remotePubSpki: ekASpki) : null;
  final sk = await deriveX3DHSecret(dh1: dh1, dh2: dh2, dh3: dh3, dh4: dh4);
  return (sk: sk, usedOpk: opkBPriv != null);
}

/// Mint a one-shot ephemeral ECDH P-256 pair. Used by the initiator exactly
/// once per new session.
Future<EcKeyPair> generateEphemeralECDHPair() => _ecdh.newKeyPair();

/// Serialize an ECDH P-256 public key as 91-byte SPKI bytes — what goes on the
/// wire and into handshake payloads. Equivalent to the JS-side
/// `crypto.subtle.exportKey('spki', pub)`.
Future<Uint8List> exportECDHPubSpki(EcKeyPair keyPair) async {
  final pub = await keyPair.extractPublicKey();
  return buildP256Spki(x: pub.x, y: pub.y);
}
