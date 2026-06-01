// Port of src/core/bundleCache.js.
//
// Once we've received a peer's bundle over the wire and run it through
// [verifyRemoteBundle] + TOFU pin check, we stash a serialized copy here
// so the next outbound X3DH session can start without round-tripping.
//
// Rows live alongside peer pins in the `keys` table, under the
// `peer-bundle-<peerId>` row id — one place for all per-peer long-term
// trust state.

import 'identity_key.dart' as identity_key;
import 'key_store.dart';
import 'peer_pins.dart';
import 'prekey_bundle.dart';

const String _rowPrefix = 'peer-bundle-';
const String _keysTable = 'keys';

String _rowKey(String peerId) => '$_rowPrefix$peerId';

/// A cached bundle along with the cheap metadata callers usually want
/// alongside it.
class CachedBundle {
  const CachedBundle({
    required this.peerId,
    required this.bundle,
    required this.fingerprint,
    required this.storedAt,
  });
  final String peerId;
  final PrekeyBundle bundle;
  final String fingerprint;
  final int storedAt;
}

/// Persist an already-verified bundle. Callers must have verified signatures
/// and checked the TOFU pin first — use [acceptIncomingBundle] for the full
/// verify + pin + store path.
Future<bool> cacheVerifiedBundle(String peerId, PrekeyBundle bundle) async {
  if (peerId.isEmpty) {
    throw ArgumentError('cacheVerifiedBundle: peerId required');
  }
  final wire = serializeBundle(bundle);
  final fingerprint =
      await identity_key.computeFingerprint(bundle.identitySpki);
  await keyStore().put(_keysTable, {
    'id': _rowKey(peerId),
    'peerId': peerId,
    'wire': wire,
    'fingerprint': fingerprint,
    'storedAt': DateTime.now().millisecondsSinceEpoch,
  });
  return true;
}

/// Retrieve a cached bundle or null. Malformed rows are dropped on the way
/// out so downstream callers never see them.
Future<CachedBundle?> getCachedBundle(String peerId) async {
  if (peerId.isEmpty) return null;
  final row = await keyStore().get(_keysTable, _rowKey(peerId));
  if (row == null) return null;
  final wire = row['wire'];
  if (wire is! Map) return null;
  try {
    final bundle = parseBundle(Map<String, Object?>.from(wire));
    return CachedBundle(
      peerId: (row['peerId'] as String?) ?? peerId,
      bundle: bundle,
      fingerprint: (row['fingerprint'] as String?) ?? '',
      storedAt: (row['storedAt'] as num?)?.toInt() ?? 0,
    );
  } catch (_) {
    try {
      await keyStore().delete(_keysTable, _rowKey(peerId));
    } catch (_) {}
    return null;
  }
}

Future<bool> deleteCachedBundle(String peerId) async {
  if (peerId.isEmpty) return false;
  await keyStore().delete(_keysTable, _rowKey(peerId));
  return true;
}

/// Outcome of the accept path. `ok=true` implies the bundle was stored;
/// `status` mirrors the TOFU pin state so the UI can distinguish "first
/// contact" from "rotation detected".
class AcceptBundleResult {
  const AcceptBundleResult({
    required this.ok,
    this.reason,
    this.status,
    this.bundle,
    this.pinStatus,
  });
  final bool ok;
  final String? reason;

  /// One of 'pinned' | 'newPin' | 'mismatch' — same vocabulary as [PinStatus],
  /// kept as strings so this type stays JSON-serializable.
  final String? status;
  final PrekeyBundle? bundle;
  final PinCheck? pinStatus;
}

String _pinStatusName(PinStatus s) {
  switch (s) {
    case PinStatus.pinned:
      return 'pinned';
    case PinStatus.newPin:
      return 'new';
    case PinStatus.mismatch:
      return 'mismatch';
    case PinStatus.crossBound:
      return 'crossBound';
  }
}

/// Full accept path for an incoming bundle:
///
///   1. Parse + signature check ([verifyRemoteBundle]).
///   2. Bind the bundle to the claimed peerId — refuse bundles that don't
///      match the transport sender.
///   3. TOFU pin check on `bundle.identitySpki`:
///        - newPin:   accept; caller decides whether to pin (first contact).
///        - pinned:   accept; fingerprint matches.
///        - mismatch: refuse — identity swap, requires user intervention.
///   4. Persist to cache.
Future<AcceptBundleResult> acceptIncomingBundle({
  required String senderPeerId,
  required Map<String, Object?> wire,
}) async {
  if (senderPeerId.isEmpty) {
    return const AcceptBundleResult(ok: false, reason: 'missing senderPeerId');
  }

  PrekeyBundle bundle;
  try {
    bundle = parseBundle(wire);
  } catch (err) {
    return AcceptBundleResult(ok: false, reason: 'parse: $err');
  }

  if (bundle.peerId != senderPeerId) {
    return const AcceptBundleResult(
      ok: false,
      reason: 'bundle peerId does not match sender',
    );
  }

  final verify = await verifyRemoteBundle(bundle);
  if (!verify.ok) {
    return AcceptBundleResult(
      ok: false,
      reason: verify.reason ?? 'signature invalid',
    );
  }

  final pin = await checkPin(senderPeerId, bundle.identitySpki);
  if (pin.status == PinStatus.mismatch || pin.status == PinStatus.crossBound) {
    return AcceptBundleResult(
      ok: false,
      status: _pinStatusName(pin.status),
      reason: pin.status == PinStatus.crossBound
          ? 'identity key already bound to a different peer'
          : 'identity fingerprint mismatch',
      pinStatus: pin,
    );
  }

  await cacheVerifiedBundle(senderPeerId, bundle);
  return AcceptBundleResult(
    ok: true,
    status: _pinStatusName(pin.status),
    bundle: bundle,
    pinStatus: pin,
  );
}

/// Debug/devtools listing — small set, not a hot path.
class CachedBundleSummary {
  const CachedBundleSummary({
    required this.peerId,
    required this.fingerprint,
    required this.storedAt,
  });
  final String peerId;
  final String fingerprint;
  final int storedAt;
}

Future<List<CachedBundleSummary>> listCachedBundles() async {
  final rows = await keyStore().getAll(_keysTable);
  final out = <CachedBundleSummary>[];
  for (final r in rows) {
    final id = r['id'];
    if (id is! String || !id.startsWith(_rowPrefix)) continue;
    out.add(CachedBundleSummary(
      peerId: (r['peerId'] as String?) ?? id.substring(_rowPrefix.length),
      fingerprint: (r['fingerprint'] as String?) ?? '',
      storedAt: (r['storedAt'] as num?)?.toInt() ?? 0,
    ));
  }
  return out;
}
