// Signed relay registration (relay Phase 2).
//
// Authenticates a client to the relay server so another client cannot simply
// register as someone else's peer id and intercept/misroute their relayed
// frames. The client signs a CANONICAL registration blob with its long-term
// ECDSA P-256 identity key (the same key peers pin via TOFU — see
// identity_key.dart); the server verifies the signature and pins the key
// (server-side TOFU). This does NOT touch the end-to-end Double-Ratchet crypto
// and never sends any private key material to the server.
//
// The blob is a FROZEN wire format — the byte-identical builder must exist on
// both client (here) and server (relay-server/src/register-blob.js). Any drift
// breaks every signature. It is covered by golden-string tests on both sides.

import 'dart:convert';
import 'dart:typed_data';

import '../core/base64_helpers.dart';
import '../core/identity_key.dart';

/// Canonical registration blob, v1. UTF-8, exact newlines, no JSON. MUST match
/// `buildRelayRegisterBlob` in relay-server/src/register-blob.js byte-for-byte.
///
///   orbits-relay-register-v1
///   peer:<peerId>
///   nonce:<nonce>
///   ts:<ts>
///   relay:<relay>
String buildRelayRegisterBlob({
  required String peer,
  required String nonce,
  required int ts,
  required String relay,
}) =>
    'orbits-relay-register-v1\n'
    'peer:$peer\n'
    'nonce:$nonce\n'
    'ts:$ts\n'
    'relay:$relay';

/// The blob as UTF-8 bytes (what actually gets signed).
Uint8List buildRelayRegisterBlobBytes({
  required String peer,
  required String nonce,
  required int ts,
  required String relay,
}) =>
    Uint8List.fromList(utf8.encode(
      buildRelayRegisterBlob(peer: peer, nonce: nonce, ts: ts, relay: relay),
    ));

/// Produces the signed `register` message for a server challenge, or `null` on
/// failure (e.g. identity not ready / vault locked). Injectable so the
/// transport can be unit-tested without real P-256 crypto.
typedef RelaySigner = Future<Map<String, Object?>?> Function({
  required String peer,
  required String nonce,
  required int ts,
  required String relay,
});

/// Default signer: signs the canonical blob with the local ECDSA identity and
/// returns the wire `register` message. `idPub` is the base64 of the 91-byte
/// P-256 SPKI; `sig` is the base64 of the raw 64-byte R||S (IEEE P1363)
/// signature — both directly verifiable by Node's `crypto` on the server.
Future<Map<String, Object?>?> defaultRelaySigner({
  required String peer,
  required String nonce,
  required int ts,
  required String relay,
}) async {
  try {
    final blob =
        buildRelayRegisterBlobBytes(peer: peer, nonce: nonce, ts: ts, relay: relay);
    final sig = await signBytes(blob);
    final idPub = await exportIdentityPubSpki();
    return <String, Object?>{
      'type': 'register',
      'peer': peer,
      'ts': ts,
      'nonce': nonce,
      'idPub': bytesToBase64(idPub),
      'sig': bytesToBase64(sig),
    };
  } catch (_) {
    // Identity not ready / signing failed → no register. The transport keeps
    // the relay unregistered (so it won't send frames) and surfaces a
    // diagnostic; messages fall back to WebRTC / stay pending.
    return null;
  }
}
