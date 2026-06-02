// Canonical relay registration blob, v1. UTF-8, exact newlines, no JSON.
//
// FROZEN WIRE FORMAT. This MUST stay byte-for-byte identical to the Dart
// builder in lib/peer/relay_auth.dart::buildRelayRegisterBlob — the client
// signs these exact bytes and the server verifies them. Any drift breaks every
// signature. Covered by golden-string tests on both sides.
//
//   orbits-relay-register-v1
//   peer:<peerId>
//   nonce:<nonce>
//   ts:<ts>
//   relay:<relay>

export function buildRelayRegisterBlob({ peer, nonce, ts, relay }) {
  return (
    'orbits-relay-register-v1\n' +
    `peer:${peer}\n` +
    `nonce:${nonce}\n` +
    `ts:${ts}\n` +
    `relay:${relay}`
  );
}
