// Port of src/core/peerPins.js — TOFU pin store for remote identity keys.
//
// The first time a peer completes a signed (v3+) handshake we pin the SHA-256
// fingerprint of their identity pubkey. Every subsequent handshake must hash
// to the same fingerprint; a mismatch flags either legitimate key rotation
// (app reinstall) or an active MITM. We deliberately do not auto-overwrite —
// the user has to clear the pin before a different key is accepted.

import 'dart:typed_data';

import 'base64_helpers.dart';
import 'identity_key.dart' as identity_key;
import 'key_store.dart';

const String _pinPrefix = 'peer-pin-';
const String _fpPrefix = 'peer-fp-';
const String _keysTable = 'keys';

String _rowKey(String peerId) => '$_pinPrefix$peerId';
String _fpRowKey(String fingerprint) => '$_fpPrefix$fingerprint';

/// Which peerId (if any) already has [fingerprint] pinned. Powers the
/// src⇄fingerprint binding invariant (audit finding 9): one identity key must
/// not be pinned under two different transport ids.
Future<String?> peerIdForFingerprint(String fingerprint) async {
  if (fingerprint.isEmpty) return null;
  final row = await keyStore().get(_keysTable, _fpRowKey(fingerprint));
  final pid = row?['peerId'];
  return pid is String && pid.isNotEmpty ? pid : null;
}

/// Stored pin snapshot. [pinnedAt] is a unix epoch ms.
class PeerPin {
  const PeerPin({
    required this.peerId,
    required this.pubSpkiB64,
    required this.fingerprint,
    required this.pinnedAt,
  });
  final String peerId;
  final String pubSpkiB64;
  final String fingerprint;
  final int pinnedAt;
}

Future<PeerPin?> getPin(String peerId) async {
  if (peerId.isEmpty) return null;
  final row = await keyStore().get(_keysTable, _rowKey(peerId));
  if (row == null) return null;
  final b64 = row['pubSpkiB64'];
  if (b64 is! String || b64.isEmpty) return null;
  return PeerPin(
    peerId: (row['peerId'] as String?) ?? peerId,
    pubSpkiB64: b64,
    fingerprint: (row['fingerprint'] as String?) ?? '',
    pinnedAt: (row['pinnedAt'] as num?)?.toInt() ?? 0,
  );
}

/// Pin [pubSpkiBytes] as the trusted identity for [peerId]. Returns the
/// computed fingerprint so callers can surface it in the UI immediately.
Future<({String fingerprint})> setPin(
    String peerId, List<int> pubSpkiBytes) async {
  if (peerId.isEmpty) {
    throw ArgumentError('setPin: peerId required');
  }
  final fingerprint = await identity_key.computeFingerprint(pubSpkiBytes);
  await keyStore().put(_keysTable, {
    'id': _rowKey(peerId),
    'peerId': peerId,
    'pubSpkiB64': bytesToBase64(Uint8List.fromList(pubSpkiBytes)),
    'fingerprint': fingerprint,
    'pinnedAt': DateTime.now().millisecondsSinceEpoch,
  });
  // Reverse index (fingerprint → peerId) for the src⇄fingerprint invariant.
  await keyStore().put(_keysTable, {
    'id': _fpRowKey(fingerprint),
    'peerId': peerId,
    'fingerprint': fingerprint,
  });
  return (fingerprint: fingerprint);
}

Future<bool> deletePin(String peerId) async {
  if (peerId.isEmpty) return false;
  final existing = await getPin(peerId);
  await keyStore().delete(_keysTable, _rowKey(peerId));
  // Clean the reverse-index row too, but only if it still points at us (don't
  // clobber a row another peerId owns).
  if (existing != null && existing.fingerprint.isNotEmpty) {
    final owner = await peerIdForFingerprint(existing.fingerprint);
    if (owner == peerId) {
      await keyStore().delete(_keysTable, _fpRowKey(existing.fingerprint));
    }
  }
  return true;
}

/// Pin-check outcome. The JS side uses string literals — we keep the same
/// vocabulary so UI code can port one-to-one.
enum PinStatus { pinned, newPin, mismatch, crossBound }

class PinCheck {
  const PinCheck({required this.status, required this.fingerprint, this.expected});
  final PinStatus status;
  final String fingerprint;
  final String? expected;
}

/// Verify a remote pubkey against the existing pin.
///
/// A missing or throwing pin store is an error, not `newPin`. Callers
/// must fail closed — do not treat a store failure as first contact.
Future<PinCheck> checkPin(String peerId, List<int> remoteSpkiBytes) async {
  try {
    await keyStore().get(_keysTable, '__pin-store-probe__');
  } catch (_) {
    throw StateError('pin store unavailable');
  }
  final incoming = await identity_key.computeFingerprint(remoteSpkiBytes);
  final pin = await getPin(peerId);
  if (pin == null || pin.fingerprint.isEmpty) {
    // No pin for THIS peerId yet. But if this exact identity key is already
    // pinned under a DIFFERENT peerId, that's a relay-impersonation / key-reuse
    // signal (audit finding 9) — refuse instead of silently TOFU-pinning a
    // second transport persona onto one identity. `expected` carries the other
    // peerId so callers can explain the conflict.
    final owner = await peerIdForFingerprint(incoming);
    if (owner != null && owner != peerId) {
      return PinCheck(
        status: PinStatus.crossBound,
        fingerprint: incoming,
        expected: owner,
      );
    }
    return PinCheck(status: PinStatus.newPin, fingerprint: incoming);
  }
  if (pin.fingerprint == incoming) {
    return PinCheck(status: PinStatus.pinned, fingerprint: incoming);
  }
  return PinCheck(
    status: PinStatus.mismatch,
    fingerprint: incoming,
    expected: pin.fingerprint,
  );
}

/// Convert a stored pin's base64 SPKI back into raw bytes.
Uint8List? pubSpkiBytesFromPin(PeerPin? pin) {
  if (pin == null || pin.pubSpkiB64.isEmpty) return null;
  return base64ToBytes(pin.pubSpkiB64);
}
