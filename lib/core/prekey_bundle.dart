// Port of src/core/prekeyBundle.js.
//
// A bundle is what a peer hands out so others can kick off X3DH with them
// asynchronously. Shape matches the JS side 1:1 so bundles cross between
// React and Flutter installs unchanged.
//
//   {
//     v: 1,
//     peerId,                 // advertised transport id (binds the bundle)
//     identitySpki,           // ECDSA long-term identity (TOFU anchor)
//     x3dhIdentitySpki,       // ECDH long-term identity for DH1/DH2
//     x3dhIdentitySig,        // ECDSA(identity) over x3dhIdentitySpki binding
//     spk: { id, pub, sig },  // signed prekey (rotates ~weekly)
//     opk: { id, pub } | null,// optional one-time prekey
//     createdAt
//   }
//
// All byte fields ride as base64 on the wire. [verifyRemoteBundle] checks
// both signatures; callers that care about TOFU must additionally compare
// the fingerprint of `identitySpki` against a pinned value (see peer_pins).

import 'dart:typed_data';

import '../transport/layers.dart';
import 'base64_helpers.dart';
import 'identity_key.dart' as identity_key;
import 'prekey_store.dart';

const int bundleVersion = 1;

/// In-memory bundle with raw byte fields — what callers hand to
/// [serializeBundle] or receive from [parseBundle].
class PrekeyBundle {
  const PrekeyBundle({
    required this.version,
    required this.peerId,
    required this.identitySpki,
    required this.x3dhIdentitySpki,
    required this.x3dhIdentitySig,
    required this.spk,
    required this.createdAt,
    this.opk,
  });
  final int version;
  final String peerId;
  final Uint8List identitySpki;
  final Uint8List x3dhIdentitySpki;
  final Uint8List x3dhIdentitySig;
  final BundleSpk spk;
  final BundleOpk? opk;
  final int createdAt;
}

class BundleSpk {
  const BundleSpk({required this.id, required this.pub, required this.sig});
  final String id;
  final Uint8List pub;
  final Uint8List sig;
}

class BundleOpk {
  const BundleOpk({required this.id, required this.pub});
  final String id;
  final Uint8List pub;
}

/// Build a freshly-signed bundle for the local device. Ensures the prekey
/// pool exists, pulls the active SPK, and includes one OPK when available.
/// [peerId] is the local transport (PeerJS) id — binds the bundle to the
/// advertised identity.
Future<PrekeyBundle> buildLocalBundle({
  required String peerId,
  bool includeOpk = true,
}) async {
  await ensurePrekeysReady();
  // Make sure both long-term identities exist before reading their publics.
  await identity_key.getOrCreateSigningKey();
  final x3dhIdentity = await identity_key.getOrCreateX3DHIdentity();

  final identitySpki = await identity_key.exportIdentityPubSpki();
  final x3dhIdentitySpki = await identity_key.exportX3DHIdentityPubSpki();

  final spk = await getActiveSignedPrekey();
  if (spk == null) {
    throw StateError('no active signed prekey');
  }

  BundleOpk? opk;
  if (includeOpk) {
    final fresh = await listFreshOPKs(1);
    if (fresh.isNotEmpty) {
      opk = BundleOpk(id: fresh.first.id, pub: fresh.first.pubSpki);
    }
  }

  return PrekeyBundle(
    version: bundleVersion,
    peerId: peerId,
    identitySpki: identitySpki,
    x3dhIdentitySpki: x3dhIdentitySpki,
    x3dhIdentitySig: x3dhIdentity.bindingSig,
    spk: BundleSpk(id: spk.id, pub: spk.pubSpki, sig: spk.sig),
    opk: opk,
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );
}

/// Convert a bundle to a JSON-safe map (byte fields base64-encoded).
Map<String, Object?> serializeBundle(PrekeyBundle bundle) {
  return <String, Object?>{
    'v': bundle.version,
    'peerId': bundle.peerId,
    'identitySpki': bytesToBase64(bundle.identitySpki),
    'x3dhIdentitySpki': bytesToBase64(bundle.x3dhIdentitySpki),
    'x3dhIdentitySig': bytesToBase64(bundle.x3dhIdentitySig),
    'spk': <String, Object?>{
      'id': bundle.spk.id,
      'pub': bytesToBase64(bundle.spk.pub),
      'sig': bytesToBase64(bundle.spk.sig),
    },
    'opk': bundle.opk == null
        ? null
        : <String, Object?>{
            'id': bundle.opk!.id,
            'pub': bytesToBase64(bundle.opk!.pub),
          },
    'createdAt': bundle.createdAt,
  };
}

Uint8List _requireB64Bytes(Object? v, String field) {
  if (v is! String || v.isEmpty) {
    throw FormatException('bundle: missing $field');
  }
  final b = base64ToBytes(v);
  if (b.isEmpty) {
    throw FormatException('bundle: empty $field');
  }
  return b;
}

/// Parse a wire map back into a [PrekeyBundle]. Throws [FormatException] on
/// any structural problem — callers should catch and treat as a malformed
/// bundle.
PrekeyBundle parseBundle(Map<String, Object?> wire) {
  if (!replicationValueIsSafe(wire)) {
    throw const FormatException('bundle: forbidden fields');
  }
  final v = wire['v'];
  final vNum = v is num ? v.toInt() : int.tryParse('$v');
  if (vNum != bundleVersion) {
    throw const FormatException('bundle: unsupported version');
  }
  final peerId = wire['peerId'];
  if (peerId is! String || peerId.isEmpty) {
    throw const FormatException('bundle: missing peerId');
  }

  final identitySpki = _requireB64Bytes(wire['identitySpki'], 'identitySpki');
  final x3dhIdentitySpki =
      _requireB64Bytes(wire['x3dhIdentitySpki'], 'x3dhIdentitySpki');
  final x3dhIdentitySig =
      _requireB64Bytes(wire['x3dhIdentitySig'], 'x3dhIdentitySig');

  final spkRaw = wire['spk'];
  if (spkRaw is! Map) {
    throw const FormatException('bundle: missing spk');
  }
  final spkId = spkRaw['id'];
  if (spkId is! String || spkId.isEmpty) {
    throw const FormatException('bundle: missing spk.id');
  }
  final spk = BundleSpk(
    id: spkId,
    pub: _requireB64Bytes(spkRaw['pub'], 'spk.pub'),
    sig: _requireB64Bytes(spkRaw['sig'], 'spk.sig'),
  );

  BundleOpk? opk;
  final opkRaw = wire['opk'];
  if (opkRaw is Map) {
    final opkId = opkRaw['id'];
    if (opkId is! String || opkId.isEmpty) {
      throw const FormatException('bundle: missing opk.id');
    }
    opk = BundleOpk(id: opkId, pub: _requireB64Bytes(opkRaw['pub'], 'opk.pub'));
  }

  final createdAtRaw = wire['createdAt'];
  final createdAt = createdAtRaw is num ? createdAtRaw.toInt() : 0;

  return PrekeyBundle(
    version: bundleVersion,
    peerId: peerId,
    identitySpki: identitySpki,
    x3dhIdentitySpki: x3dhIdentitySpki,
    x3dhIdentitySig: x3dhIdentitySig,
    spk: spk,
    opk: opk,
    createdAt: createdAt,
  );
}

/// Outcome of a bundle verification — matches the JS `{ ok, reason }` shape.
class BundleVerifyResult {
  const BundleVerifyResult({required this.ok, this.reason});
  final bool ok;
  final String? reason;
}

/// Verify a parsed bundle's two signatures. Does NOT enforce TOFU pinning —
/// callers that pin must compare `identitySpki`'s fingerprint separately
/// before trusting the bundle.
///
/// Checks:
///   1. `x3dhIdentitySig` is a valid ECDSA signature by `identitySpki` over
///      the x3dh binding blob.
///   2. `spk.sig` is a valid ECDSA signature by `identitySpki` over `spk.pub`.
Future<BundleVerifyResult> verifyRemoteBundle(PrekeyBundle? bundle) async {
  if (bundle == null) {
    return const BundleVerifyResult(ok: false, reason: 'no bundle');
  }

  final bindingOk = await identity_key.verifyX3DHBinding(
    bundle.identitySpki,
    bundle.x3dhIdentitySpki,
    bundle.x3dhIdentitySig,
  );
  if (!bindingOk) {
    return const BundleVerifyResult(
      ok: false,
      reason: 'x3dh binding signature invalid',
    );
  }

  final spkOk = await identity_key.verifyWithRemoteSpki(
    bundle.identitySpki,
    bundle.spk.pub,
    bundle.spk.sig,
  );
  if (!spkOk) {
    return const BundleVerifyResult(ok: false, reason: 'spk signature invalid');
  }

  return const BundleVerifyResult(ok: true);
}
