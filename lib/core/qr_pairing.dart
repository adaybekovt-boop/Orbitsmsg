// Cryptographic QR pairing protocol (Phase 5 — "log in to PC from phone").
//
// WhatsApp-style flow:
//   1. The PC (desktop) generates a fresh 32-byte one-time [sessionToken] and
//      shows a QR encoding  `orbits_pairing:<pcPeerId>:<sessionToken>`.
//   2. The phone scans it, signs the token with its long-term identity key,
//      and sends a `qr_auth_response` { peerId, pubSpki, sig } back to the PC
//      over the reliable WebRTC channel.
//   3. The PC verifies the signature against the supplied public key over the
//      token IT issued. A valid signature proves the phone holds that
//      identity key and saw this one-time token. It does NOT unlock the
//      PC vault, copy the profile, or prove the DataChannel peer is the
//      same device that displayed the QR (PeerJS id + signalling MITM).
//
// This module is the protocol core (token gen, URI build/parse, response
// build + verify). There is no UI that "adopts a session" after a
// signature — that path was deleted (Round 3 A.6). Signing / verification
// reuse the ECDSA-P256 identity in `identity_key.dart`.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'identity_key.dart';

const String kPairingScheme = 'orbits_pairing';
const String kQrAuthResponseType = 'qr_auth_response';

/// Fresh 32-byte one-time session token (base64url, no padding) from a CSPRNG.
String generateSessionToken() {
  final rng = Random.secure();
  final bytes =
      Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// The QR payload string: `orbits_pairing:<pcPeerId>:<sessionToken>`.
String buildPairingUri(String pcPeerId, String sessionToken) =>
    '$kPairingScheme:$pcPeerId:$sessionToken';

/// A parsed pairing QR.
class PairingRequest {
  const PairingRequest({required this.pcPeerId, required this.sessionToken});
  final String pcPeerId;
  final String sessionToken;
}

/// Parse a scanned QR string. Returns null if it isn't a well-formed pairing
/// URI. (The token may itself contain no ':' — we split on the FIRST ':' after
/// the peer id, treating the remainder as the token.)
PairingRequest? parsePairingUri(String raw) {
  final s = raw.trim();
  const prefix = '$kPairingScheme:';
  if (!s.startsWith(prefix)) return null;
  final rest = s.substring(prefix.length);
  final idx = rest.indexOf(':');
  if (idx <= 0) return null;
  final pcPeerId = rest.substring(0, idx);
  final token = rest.substring(idx + 1);
  if (pcPeerId.isEmpty || token.isEmpty) return null;
  return PairingRequest(pcPeerId: pcPeerId, sessionToken: token);
}

/// Phone side: sign [sessionToken] with the local identity key and build the
/// `qr_auth_response` packet for the PC at [myPeerId].
Future<Map<String, Object?>> buildAuthResponse({
  required String sessionToken,
  required String myPeerId,
}) async {
  final tokenBytes = utf8.encode(sessionToken);
  final sig = await signBytes(tokenBytes);
  final pubSpki = await exportIdentityPubSpki();
  return <String, Object?>{
    'type': kQrAuthResponseType,
    'peerId': myPeerId,
    'pubSpki': base64.encode(pubSpki),
    'sig': base64.encode(sig),
  };
}

/// The authenticated phone identity after a successful pairing.
class PairingResult {
  const PairingResult({required this.peerId, required this.pubSpki});
  final String peerId;
  final List<int> pubSpki;
}

/// PC side: verify a `qr_auth_response` against the token the PC issued.
/// Returns the authenticated peer (id + public key) on success, or null on any
/// malformed input or signature mismatch. Never throws.
Future<PairingResult?> verifyAuthResponse(
  Map<String, Object?> packet,
  String expectedToken,
) async {
  if (packet['type'] != kQrAuthResponseType) return null;
  final peerId = (packet['peerId'] as String?) ?? '';
  final pubB64 = (packet['pubSpki'] as String?) ?? '';
  final sigB64 = (packet['sig'] as String?) ?? '';
  if (peerId.isEmpty || pubB64.isEmpty || sigB64.isEmpty) return null;

  List<int> pub;
  List<int> sig;
  try {
    pub = base64.decode(pubB64);
    sig = base64.decode(sigB64);
  } catch (_) {
    return null;
  }
  final ok = await verifyWithRemoteSpki(pub, utf8.encode(expectedToken), sig);
  if (!ok) return null;
  return PairingResult(peerId: peerId, pubSpki: pub);
}
