// Port of src/core/x3dhSession.js — X3DH orchestration.
//
// Glue between the pure X3DH math (x3dh.dart), the local prekey store, and
// the cached remote bundles. Two entry points:
//
//   * [deriveInitiatorBootstrap] — alice side. Needs a cached verified bundle
//     for [peerId]. Mints EK, runs DH1..DH4, returns SK plus the fields that
//     must ride on the outgoing signed-hello v4 so bob can replay the math.
//
//   * [deriveResponderBootstrap] — bob side. Looks up his SPK priv by id,
//     optionally consumes the referenced OPK, verifies alice's x3dh-identity
//     binding, and derives the matching SK.
//
// On a successful initiator bootstrap we drop the cached bundle: reusing an
// OPK across sessions breaks forward secrecy, and bob's consume-once check
// would reject it anyway.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'bundle_cache.dart';
import 'identity_key.dart' as identity_key;
import 'prekey_store.dart';
import 'x3dh.dart';

/// Fields the initiator must put on the wire so the responder can run the
/// matching X3DH. Matches the JS return shape of [deriveInitiatorBootstrap].
class InitiatorBootstrap {
  const InitiatorBootstrap({
    required this.sk,
    required this.ekSpki,
    required this.spkId,
    required this.myX3dhIkSpki,
    required this.myX3dhIkSig,
    this.opkId,
  });

  /// 32-byte session seed for the Double Ratchet root key.
  final Uint8List sk;

  /// SPKI bytes of the fresh ephemeral ECDH pub.
  final Uint8List ekSpki;

  /// The responder's SPK id we DH'd against.
  final String spkId;

  /// The responder's OPK id we consumed, or null if none was published.
  final String? opkId;

  /// Our long-term X3DH ECDH pub SPKI.
  final Uint8List myX3dhIkSpki;

  /// Our ECDSA binding signature over [myX3dhIkSpki].
  final Uint8List myX3dhIkSig;
}

/// Attempt to bootstrap X3DH as the initiator for [peerId]. Returns null if
/// there's no cached bundle — caller should fall back to the plain DH hello.
Future<InitiatorBootstrap?> deriveInitiatorBootstrap(String peerId) async {
  final cached = await getCachedBundle(peerId);
  if (cached == null) return null;
  final bundle = cached.bundle;

  final myIdentity = await identity_key.getOrCreateX3DHIdentity();
  final myX3dhIkSpki = await identity_key.exportX3DHIdentityPubSpki();

  final ek = await generateEphemeralECDHPair();
  final ekSpki = await exportECDHPubSpki(ek);

  final result = await initiatorX3DH(
    ikAPriv: myIdentity.keyPair,
    ekAPriv: ek,
    ikBSpki: bundle.x3dhIdentitySpki,
    spkBSpki: bundle.spk.pub,
    opkBSpki: bundle.opk?.pub,
  );

  // One-shot: drop the cached bundle so the next connection pulls a fresh one
  // (bob's OPK is now consumed on his side once he processes our hello).
  try {
    await deleteCachedBundle(peerId);
  } catch (_) {}

  return InitiatorBootstrap(
    sk: result.sk,
    ekSpki: ekSpki,
    spkId: bundle.spk.id,
    opkId: bundle.opk?.id,
    myX3dhIkSpki: myX3dhIkSpki,
    myX3dhIkSig: myIdentity.bindingSig,
  );
}

/// Outcome of a responder-side bootstrap.
class ResponderBootstrap {
  const ResponderBootstrap({required this.ok, this.sk, this.reason});
  final bool ok;

  /// 32-byte session seed — present iff [ok] is true.
  final Uint8List? sk;
  final String? reason;
}

/// Replay the X3DH DHs on bob's side. Returns `ok=false` with a reason on any
/// failure (unknown SPK, already-consumed OPK, malformed binding sig, etc.)
/// so the caller can hard-fail the handshake — silently falling back to plain
/// DH would leave alice using a different bootstrap than bob.
Future<ResponderBootstrap> deriveResponderBootstrap({
  required List<int>? senderIdSpki,
  required List<int>? senderX3dhIkSpki,
  required List<int>? senderX3dhIkSig,
  required List<int>? ekSpki,
  required String? spkId,
  String? opkId,
}) async {
  if (senderIdSpki == null ||
      senderX3dhIkSpki == null ||
      senderX3dhIkSig == null) {
    return const ResponderBootstrap(
      ok: false,
      reason: 'x3dh: missing sender identity fields',
    );
  }
  if (ekSpki == null || spkId == null || spkId.isEmpty) {
    return const ResponderBootstrap(
      ok: false,
      reason: 'x3dh: missing ek or spkId',
    );
  }

  final bindingOk = await identity_key.verifyX3DHBinding(
    senderIdSpki,
    senderX3dhIkSpki,
    senderX3dhIkSig,
  );
  if (!bindingOk) {
    return const ResponderBootstrap(
      ok: false,
      reason: 'x3dh: sender binding invalid',
    );
  }

  final spk = await getSignedPrekeyById(spkId);
  if (spk == null) {
    return ResponderBootstrap(ok: false, reason: 'x3dh: unknown spk $spkId');
  }

  EcKeyPair? opkPriv;
  if (opkId != null && opkId.isNotEmpty) {
    final opk = await peekFreshOPK(opkId);
    if (opk == null) {
      return ResponderBootstrap(
        ok: false,
        reason: 'x3dh: unknown or consumed opk $opkId',
      );
    }
    opkPriv = opk.privateKey;
  }

  final myIdentity = await identity_key.getOrCreateX3DHIdentity();
  final X3dhResult result;
  try {
    result = await responderX3DH(
      spkBPriv: spk.privateKey,
      ikBPriv: myIdentity.keyPair,
      opkBPriv: opkPriv,
      ikASpki: senderX3dhIkSpki,
      ekASpki: ekSpki,
    );
  } catch (_) {
    return const ResponderBootstrap(ok: false, reason: 'x3dh: dh failed');
  }

  // Consume only after the DHs succeed. A bad EK / binding must not burn OPKs.
  if (opkId != null && opkId.isNotEmpty) {
    final marked = await consumeOPK(opkId);
    if (marked == null) {
      return ResponderBootstrap(
        ok: false,
        reason: 'x3dh: opk consumed concurrently $opkId',
      );
    }
  }
  return ResponderBootstrap(ok: true, sk: result.sk);
}
