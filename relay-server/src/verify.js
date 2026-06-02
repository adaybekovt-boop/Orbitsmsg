// Verify a signed relay registration. Uses only Node's built-in `crypto`
// (no external deps) so it runs under `node --test` without `npm install`.
//
// The client signs the canonical blob with its ECDSA P-256 identity key and
// sends:
//   idPub : base64 of the 91-byte P-256 SubjectPublicKeyInfo (SPKI DER)
//   sig   : base64 of the raw 64-byte R||S signature (IEEE P1363)
// We import the SPKI directly and verify with SHA-256 + ieee-p1363 — matching
// the client's `signBytes` (which is Web Crypto compatible).
//
// NEVER logs sig / full idPub / frame.

import crypto from 'node:crypto';
import { buildRelayRegisterBlob } from './register-blob.js';

// A P-256 SPKI from Web Crypto / the Flutter client is exactly 91 bytes; a
// raw P1363 P-256 signature is exactly 64 bytes. Reject anything else early.
const P256_SPKI_LEN = 91;
const P256_P1363_SIG_LEN = 64;

/**
 * @returns {{ ok: true } | { ok: false, reason: string }}
 */
export function verifyRegistration({ peer, nonce, ts, relay, idPubB64, sigB64 }) {
  if (typeof idPubB64 !== 'string' || idPubB64.length === 0) {
    return { ok: false, reason: 'missing_idpub' };
  }
  if (typeof sigB64 !== 'string' || sigB64.length === 0) {
    return { ok: false, reason: 'missing_sig' };
  }

  let der;
  try {
    der = Buffer.from(idPubB64, 'base64');
  } catch {
    return { ok: false, reason: 'bad_idpub' };
  }
  if (der.length !== P256_SPKI_LEN) return { ok: false, reason: 'bad_idpub' };

  let sig;
  try {
    sig = Buffer.from(sigB64, 'base64');
  } catch {
    return { ok: false, reason: 'bad_sig' };
  }
  if (sig.length !== P256_P1363_SIG_LEN) return { ok: false, reason: 'bad_sig' };

  let key;
  try {
    key = crypto.createPublicKey({ key: der, format: 'der', type: 'spki' });
    // Defence in depth: must be an EC P-256 key, not some other algorithm.
    const details = key.asymmetricKeyDetails;
    if (key.asymmetricKeyType !== 'ec' ||
        (details && details.namedCurve && details.namedCurve !== 'prime256v1')) {
      return { ok: false, reason: 'bad_idpub' };
    }
  } catch {
    return { ok: false, reason: 'bad_idpub' };
  }

  const blob = Buffer.from(
    buildRelayRegisterBlob({ peer, nonce, ts, relay }),
    'utf8',
  );

  let valid = false;
  try {
    valid = crypto.verify('sha256', blob, { key, dsaEncoding: 'ieee-p1363' }, sig);
  } catch {
    valid = false;
  }
  return valid ? { ok: true } : { ok: false, reason: 'bad_signature' };
}
