// Port of src/core/identityKey.js.
//
// Every install keeps two long-term key pairs:
//
//   • ECDSA P-256 signing pair (`identity-signing-v1`) — the stable identity.
//     Its public SPKI is what peers pin via TOFU. It signs handshake blobs
//     (wireHello v3/v4), prekeys, and the X3DH ECDH binding.
//
//   • ECDH P-256 key agreement pair (`identity-x3dh-v1`) — used in DH1/DH2
//     of X3DH. Bound to the ECDSA identity by a signature over its public
//     SPKI, so TOFU on the ECDSA identity transitively trusts the ECDH half
//     without a second fingerprint comparison.
//
// Private keys are held in memory after first load; persistence is delegated
// to [KeyStore] (backed by in-memory for now, swap to Isar/Hive later — the
// JS side uses IndexedDB with non-extractable CryptoKey structured clones,
// which has no Flutter equivalent; we extract raw private-key bytes and
// re-import, relying on the vault KEK + OS secure storage to protect them).

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'base64_helpers.dart';
import 'key_store.dart';
import 'spki_codec.dart';
import 'vault_kek.dart';

const String _signingKeyId = 'identity-signing-v1';
const String _x3dhKeyId = 'identity-x3dh-v1';
const String _keysTable = 'keys';
const String _x3dhBindingLabel = 'orbits-x3dh-ik-v1\n';

final _ecdsa = Ecdsa.p256(Sha256());
final _ecdh = Ecdh.p256(length: 32);

EcKeyPair? _cachedSigningKeyPair;
Uint8List? _cachedSigningPubSpki;
String? _cachedFingerprint;

EcKeyPair? _cachedX3dhKeyPair;
Uint8List? _cachedX3dhPubSpki;
Uint8List? _cachedX3dhBindingSig;

// ─────────────────────────────────────────────────────────────
// Generic helpers (private-key round-trip + SPKI export)
// ─────────────────────────────────────────────────────────────

Future<Uint8List> _exportPubSpki(EcKeyPair keyPair) async {
  final pub = await keyPair.extractPublicKey();
  return buildP256Spki(x: pub.x, y: pub.y);
}

Future<Map<String, Object?>> _serializeKeyPair(
  EcKeyPair keyPair, {
  required Uint8List pubSpki,
}) async {
  // cryptography 2.9 removed the `extractPrivateKeyBytes` shortcut for
  // EcKeyPair — `extract()` returns an EcKeyPairData whose `d` is the raw
  // scalar. Same bytes, extra await hop.
  final priv = (await keyPair.extract()).d;
  // The long-term identity scalar is the crown jewel — it signs the TOFU pin
  // and the X3DH binding. Wrap it under the vault KEK before it touches disk
  // (audit C2). [wrapSecret] fails closed if the vault is locked rather than
  // writing plaintext, so this never silently degrades.
  return {
    'privBytes': await wrapSecret(priv),
    'privEnc': 1,
    'pubSpki': pubSpki,
  };
}

/// Rehydrate a P-256 keypair from a stored row. [algo] controls the returned
/// key type (ECDSA vs ECDH) — both live at the same raw 32-byte secret, but
/// the `cryptography` package keys them apart by KeyPairType on the public
/// half.
Future<EcKeyPair> _importKeyPair(
  Map<String, Object?> row, {
  required bool ecdsa,
}) async {
  final privRaw = row['privBytes'];
  final pubSpkiRaw = row['pubSpki'];
  if (privRaw == null || pubSpkiRaw is! List<int>) {
    throw StateError('identity: stored row is missing key bytes');
  }
  // Tolerates both the wrapped form (current) and a legacy plaintext byte
  // field (rows written before C2 landed — migrated opportunistically by the
  // get-or-create callers below).
  final priv = await unwrapSecret(privRaw);
  final point = parseP256Spki(pubSpkiRaw);
  // EcKeyPairData needs the scalar (`d`) and both public affine coords
  // separately — unlike the old SimpleKeyPairData shape which bundled the
  // public key object. Same semantic, different constructor.
  return EcKeyPairData(
    d: priv,
    x: point.x,
    y: point.y,
    type: KeyPairType.p256,
  );
}

/// Re-encrypt a row whose `privBytes` predates C2 (stored as raw bytes rather
/// than a vault-wrapped string). Best-effort: a locked vault or a write error
/// leaves the legacy row in place to retry next launch. No-op once wrapped.
Future<void> _migrateLegacyPlaintext(
  String id,
  Map<String, Object?> existing,
) async {
  if (isWrapped(existing['privBytes']) || !hasVaultKek()) return;
  final priv = existing['privBytes'];
  if (priv is! List<int>) return;
  try {
    await keyStore().put(_keysTable, {
      ...existing,
      'privBytes': await wrapSecret(priv),
      'privEnc': 1,
    });
  } catch (_) {
    // Migration is opportunistic — never block identity load on it.
  }
}

// ─────────────────────────────────────────────────────────────
// ECDSA signing identity
// ─────────────────────────────────────────────────────────────

/// Return the cached identity signing key pair, creating+persisting one on
/// first call. Mirrors `getOrCreateSigningKey`.
Future<EcKeyPair> getOrCreateSigningKey() async {
  if (_cachedSigningKeyPair != null) return _cachedSigningKeyPair!;

  final existing = await keyStore().get(_keysTable, _signingKeyId);
  if (existing != null) {
    _cachedSigningKeyPair = await _importKeyPair(existing, ecdsa: true);
    _cachedSigningPubSpki = Uint8List.fromList(existing['pubSpki'] as List<int>);
    await _migrateLegacyPlaintext(_signingKeyId, existing);
    return _cachedSigningKeyPair!;
  }

  final pair = await _ecdsa.newKeyPair();
  final pubSpki = await _exportPubSpki(pair);
  final row = await _serializeKeyPair(pair, pubSpki: pubSpki);
  await keyStore().put(_keysTable, {
    'id': _signingKeyId,
    ...row,
    'createdAt': DateTime.now().millisecondsSinceEpoch,
  });
  _cachedSigningKeyPair = pair;
  _cachedSigningPubSpki = pubSpki;
  _cachedFingerprint = null;
  return pair;
}

/// SPKI bytes of the local identity public key.
Future<Uint8List> exportIdentityPubSpki() async {
  if (_cachedSigningPubSpki != null) return _cachedSigningPubSpki!;
  final pair = await getOrCreateSigningKey();
  final spki = await _exportPubSpki(pair);
  _cachedSigningPubSpki = spki;
  return spki;
}

/// SHA-256 fingerprint (lowercase hex) over raw SPKI bytes.
Future<String> computeFingerprint(List<int> spkiBytes) async {
  final hash = await Sha256().hash(spkiBytes);
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Local identity fingerprint, cached.
Future<String> getLocalIdentityFingerprint() async {
  if (_cachedFingerprint != null) return _cachedFingerprint!;
  final spki = await exportIdentityPubSpki();
  _cachedFingerprint = await computeFingerprint(spki);
  return _cachedFingerprint!;
}

/// 16-hex-char short fingerprint for compact display.
String shortFingerprint(String fingerprint) =>
    fingerprint.length <= 16 ? fingerprint : fingerprint.substring(0, 16);

/// Sign [dataBytes] with the local ECDSA identity. Returns a raw 64-byte
/// R||S signature (IEEE P1363) matching Web Crypto's output.
Future<Uint8List> signBytes(List<int> dataBytes) async {
  final pair = await getOrCreateSigningKey();
  final sig = await _ecdsa.sign(dataBytes, keyPair: pair);
  return Uint8List.fromList(sig.bytes);
}

/// Verify an ECDSA-P256/SHA-256 signature against a remote SPKI pubkey. Never
/// throws for bad inputs — returns false so callers can treat them uniformly.
Future<bool> verifyWithRemoteSpki(
  List<int>? remoteSpkiBytes,
  List<int>? dataBytes,
  List<int>? sigBytes,
) async {
  if (remoteSpkiBytes == null || dataBytes == null || sigBytes == null) {
    return false;
  }
  try {
    final point = parseP256Spki(remoteSpkiBytes);
    final pub = EcPublicKey(
      x: point.x,
      y: point.y,
      type: KeyPairType.p256,
    );
    return await _ecdsa.verify(
      dataBytes,
      signature: Signature(sigBytes, publicKey: pub),
    );
  } catch (_) {
    return false;
  }
}

/// Canonical signed-hello blob. Both sides must generate byte-identical
/// output or the signature won't verify — treat this function as a frozen
/// wire format. Mirrors `buildSignedHelloBlob` in identityKey.js.
///
/// v3: 5 lines. v4 (when [x3dhExtras] is non-null): adds 4 extra lines so
/// the X3DH bootstrap fields are bound into the signature too.
Uint8List buildSignedHelloBlob({
  required String senderPeerId,
  required String receiverPeerId,
  required List<int> senderDhSpki,
  required List<int> senderIdSpki,
  X3dhHelloExtras? x3dhExtras,
}) {
  final parts = <String>[
    x3dhExtras != null ? 'orbits-wire-v4' : 'orbits-wire-v3',
    senderPeerId,
    receiverPeerId,
    bytesToBase64(Uint8List.fromList(senderDhSpki)),
    bytesToBase64(Uint8List.fromList(senderIdSpki)),
  ];
  if (x3dhExtras != null) {
    parts.add(bytesToBase64(Uint8List.fromList(x3dhExtras.x3dhIkSpki)));
    parts.add(bytesToBase64(Uint8List.fromList(x3dhExtras.ekSpki)));
    parts.add(x3dhExtras.spkId);
    parts.add(x3dhExtras.opkId ?? '');
  }
  return Uint8List.fromList(utf8.encode(parts.join('\n')));
}

/// X3DH fields that ride inside the signed hello when v4 bootstrap is used.
class X3dhHelloExtras {
  const X3dhHelloExtras({
    required this.x3dhIkSpki,
    required this.ekSpki,
    required this.spkId,
    this.opkId,
  });
  final List<int> x3dhIkSpki;
  final List<int> ekSpki;
  final String spkId;
  final String? opkId;
}

// ─────────────────────────────────────────────────────────────
// X3DH long-term ECDH identity
// ─────────────────────────────────────────────────────────────

Uint8List _buildX3dhBindingBlob(List<int> x3dhPubSpki) {
  final prefix = utf8.encode(_x3dhBindingLabel);
  final out = Uint8List(prefix.length + x3dhPubSpki.length)
    ..setRange(0, prefix.length, prefix)
    ..setRange(prefix.length, prefix.length + x3dhPubSpki.length, x3dhPubSpki);
  return out;
}

/// Bundle of the long-term X3DH ECDH identity along with the ECDSA signature
/// that binds it to the primary identity.
class X3dhIdentity {
  const X3dhIdentity({
    required this.keyPair,
    required this.bindingSig,
    required this.pubSpki,
  });
  final EcKeyPair keyPair;
  final Uint8List bindingSig;
  final Uint8List pubSpki;
}

/// Return the cached long-term X3DH ECDH pair, creating+persisting one on
/// first call. The freshly-minted pub is signed with the ECDSA identity so
/// remote peers can bind the two halves together without a second TOFU step.
Future<X3dhIdentity> getOrCreateX3DHIdentity() async {
  if (_cachedX3dhKeyPair != null &&
      _cachedX3dhBindingSig != null &&
      _cachedX3dhPubSpki != null) {
    return X3dhIdentity(
      keyPair: _cachedX3dhKeyPair!,
      bindingSig: _cachedX3dhBindingSig!,
      pubSpki: _cachedX3dhPubSpki!,
    );
  }

  final existing = await keyStore().get(_keysTable, _x3dhKeyId);
  if (existing != null) {
    final pair = await _importKeyPair(existing, ecdsa: false);
    final pubSpki = Uint8List.fromList(existing['pubSpki'] as List<int>);
    final bindingSig =
        Uint8List.fromList(existing['bindingSig'] as List<int>);
    _cachedX3dhKeyPair = pair;
    _cachedX3dhPubSpki = pubSpki;
    _cachedX3dhBindingSig = bindingSig;
    await _migrateLegacyPlaintext(_x3dhKeyId, existing);
    return X3dhIdentity(
      keyPair: pair,
      bindingSig: bindingSig,
      pubSpki: pubSpki,
    );
  }

  final pair = await _ecdh.newKeyPair();
  final pubSpki = await _exportPubSpki(pair);
  final bindingSig = await signBytes(_buildX3dhBindingBlob(pubSpki));
  final row = await _serializeKeyPair(pair, pubSpki: pubSpki);
  await keyStore().put(_keysTable, {
    'id': _x3dhKeyId,
    ...row,
    'bindingSig': bindingSig,
    'createdAt': DateTime.now().millisecondsSinceEpoch,
  });
  _cachedX3dhKeyPair = pair;
  _cachedX3dhPubSpki = pubSpki;
  _cachedX3dhBindingSig = bindingSig;
  return X3dhIdentity(
    keyPair: pair,
    bindingSig: bindingSig,
    pubSpki: pubSpki,
  );
}

Future<Uint8List> exportX3DHIdentityPubSpki() async {
  if (_cachedX3dhPubSpki != null) return _cachedX3dhPubSpki!;
  final id = await getOrCreateX3DHIdentity();
  return id.pubSpki;
}

/// Verify an X3DH identity binding. Callers should also verify the ECDSA
/// identity itself (TOFU pin) — this only confirms the link.
Future<bool> verifyX3DHBinding(
  List<int> identitySpki,
  List<int> x3dhPubSpki,
  List<int> bindingSig,
) =>
    verifyWithRemoteSpki(
      identitySpki,
      _buildX3dhBindingBlob(x3dhPubSpki),
      bindingSig,
    );

/// Drop all in-memory identity caches so the next call re-reads (or
/// regenerates) from storage. Call after wiping the `keys` table on a full
/// local reset (audit H4) — otherwise the cached old key pair would shadow
/// the wiped store and the regenerated identity would never be persisted.
void resetIdentityCaches() {
  _cachedSigningKeyPair = null;
  _cachedSigningPubSpki = null;
  _cachedFingerprint = null;
  _cachedX3dhKeyPair = null;
  _cachedX3dhPubSpki = null;
  _cachedX3dhBindingSig = null;
}

/// Test alias for [resetIdentityCaches].
void resetIdentityCacheForTests() => resetIdentityCaches();
