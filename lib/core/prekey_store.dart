// Port of src/core/prekeyStore.js — SPK + OPK management for X3DH.
//
// Bundle we hand out:
//   { IK_pub, SPK{id, pub, sig}, OPK{id, pub}? }
// where SPK_sig = ECDSA(identityKey) over SPK_pub_spki.
//
// SPK lifecycle:
//   - exactly one `active` SPK at a time (the one we publish);
//   - on rotation the previous active is demoted to `retired` for a grace
//     window so late inbound still decrypts;
//   - [pruneRetiredSPKs] drops ones older than the window.
//
// OPK lifecycle:
//   - pool of N unused OPKs;
//   - [consumeOPK] flips `used=true` — X3DH forward secrecy depends on
//     never reusing an OPK;
//   - [pruneUsedOPKs] drops spent entries after a short grace window.

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'identity_key.dart' as identity_key;
import 'key_store.dart';
import 'spki_codec.dart';
import 'vault_kek.dart';

const String _prekeysTable = 'prekeys';

const int _spkRotationMs = 7 * 24 * 60 * 60 * 1000; // 7 days
const int _usedOpkRetentionMs = 24 * 60 * 60 * 1000; // 1 day
const int _defaultOpkPoolSize = 100;
const int _retiredSpkGraceMs = 14 * 24 * 60 * 60 * 1000;

final _ecdh = Ecdh.p256(length: 32);
final _secureRandom = Random.secure();

String _randomId(String prefix) {
  final bytes = List<int>.generate(8, (_) => _secureRandom.nextInt(256));
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '$prefix-$hex';
}

Future<EcKeyPair> _generateEcdhPair() => _ecdh.newKeyPair();

Future<Uint8List> _exportSpki(EcKeyPair pair) async {
  final pub = await pair.extractPublicKey();
  return buildP256Spki(x: pub.x, y: pub.y);
}

Future<Uint8List> _extractPriv(EcKeyPair pair) async =>
    // cryptography 2.9: `extractPrivateKeyBytes` is SimpleKeyPair-only.
    // For EcKeyPair, extract to data then read the scalar `d`.
    Uint8List.fromList((await pair.extract()).d);

/// Public info about a signed prekey.
class SignedPrekey {
  const SignedPrekey({
    required this.id,
    required this.pubSpki,
    required this.sig,
  });
  final String id;
  final Uint8List pubSpki;
  final Uint8List sig;
}

/// Full SPK record — what gets persisted and what X3DH responders load to DH
/// against incoming hellos.
class SignedPrekeyRecord {
  const SignedPrekeyRecord({
    required this.id,
    required this.status,
    required this.pubSpki,
    required this.sig,
    required this.privateKey,
    required this.createdAt,
    this.retiredAt,
  });
  final String id;
  final String status; // 'active' | 'retired'
  final Uint8List pubSpki;
  final Uint8List sig;
  final EcKeyPair privateKey;
  final int createdAt;
  final int? retiredAt;
}

Future<SignedPrekeyRecord?> _rowToSpk(Map<String, Object?> row) async {
  if (row['kind'] != 'spk') return null;
  final privRaw = row['privBytes'];
  final pubSpki = row['pubSpki'];
  final sig = row['sig'];
  if (privRaw == null || pubSpki is! List<int> || sig is! List<int>) {
    return null;
  }
  // Wrapped under the vault KEK at rest (audit C2); tolerates legacy plaintext.
  final Uint8List privBytes;
  try {
    privBytes = await unwrapSecret(privRaw);
  } catch (_) {
    return null;
  }
  final point = parseP256Spki(pubSpki);
  // EcKeyPairData constructor wants d/x/y split (see identity_key.dart for
  // the migration notes from cryptography 2.7 → 2.9).
  final keyPair = EcKeyPairData(
    d: privBytes,
    x: point.x,
    y: point.y,
    type: KeyPairType.p256,
  );
  return SignedPrekeyRecord(
    id: row['id'] as String,
    status: (row['status'] as String?) ?? 'retired',
    pubSpki: Uint8List.fromList(pubSpki),
    sig: Uint8List.fromList(sig),
    privateKey: keyPair,
    createdAt: (row['createdAt'] as num?)?.toInt() ?? 0,
    retiredAt: (row['retiredAt'] as num?)?.toInt(),
  );
}

/// Generate a fresh SPK, sign it with the local identity, and persist as
/// the new active SPK. Any prior active SPK gets demoted to `retired`.
Future<SignedPrekey> rotateSignedPrekey() async {
  final pair = await _generateEcdhPair();
  final pubSpki = await _exportSpki(pair);
  final sig = await identity_key.signBytes(pubSpki);
  final privBytes = await _extractPriv(pair);
  final id = _randomId('spk');

  final all = await keyStore()
      .getAll(_prekeysTable, indexField: 'kind', indexValue: 'spk');
  for (final r in all) {
    if (r['status'] == 'active') {
      await keyStore().put(_prekeysTable, {
        ...r,
        'status': 'retired',
        'retiredAt': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  await keyStore().put(_prekeysTable, {
    'id': id,
    'kind': 'spk',
    'status': 'active',
    'used': 0,
    'privBytes': await wrapSecret(privBytes),
    'privEnc': 1,
    'pubSpki': pubSpki,
    'sig': sig,
    'createdAt': DateTime.now().millisecondsSinceEpoch,
  });

  return SignedPrekey(id: id, pubSpki: pubSpki, sig: sig);
}

Future<SignedPrekeyRecord?> getActiveSignedPrekey() async {
  final rows = await keyStore()
      .getAll(_prekeysTable, indexField: 'kind', indexValue: 'spk');
  for (final row in rows) {
    if (row['status'] == 'active') return _rowToSpk(row);
  }
  return null;
}

Future<SignedPrekeyRecord?> getSignedPrekeyById(String id) async {
  final row = await keyStore().get(_prekeysTable, id);
  if (row == null) return null;
  return _rowToSpk(row);
}

Future<int> pruneRetiredSPKs({int maxAgeMs = _retiredSpkGraceMs}) async {
  final cutoff = DateTime.now().millisecondsSinceEpoch - maxAgeMs;
  final rows = await keyStore()
      .getAll(_prekeysTable, indexField: 'kind', indexValue: 'spk');
  var removed = 0;
  for (final row in rows) {
    if (row['status'] == 'retired') {
      final retiredAt = (row['retiredAt'] as num?)?.toInt() ?? 0;
      if (retiredAt < cutoff) {
        await keyStore().delete(_prekeysTable, row['id'] as String);
        removed++;
      }
    }
  }
  return removed;
}

// ─── OPKs ──────────────────────────────────────────────────────────

/// Public one-time prekey (id + SPKI).
class OneTimePrekey {
  const OneTimePrekey({required this.id, required this.pubSpki});
  final String id;
  final Uint8List pubSpki;
}

/// Full OPK record — what the responder loads to perform DH4.
class OneTimePrekeyRecord {
  const OneTimePrekeyRecord({
    required this.id,
    required this.pubSpki,
    required this.privateKey,
    required this.used,
    required this.createdAt,
    this.usedAt,
  });
  final String id;
  final Uint8List pubSpki;
  final EcKeyPair privateKey;
  final int used;
  final int createdAt;
  final int? usedAt;
}

Future<OneTimePrekeyRecord?> _rowToOpk(Map<String, Object?> row) async {
  if (row['kind'] != 'opk') return null;
  final privRaw = row['privBytes'];
  final pubSpki = row['pubSpki'];
  if (privRaw == null || pubSpki is! List<int>) return null;
  // Wrapped under the vault KEK at rest (audit C2); tolerates legacy plaintext.
  final Uint8List privBytes;
  try {
    privBytes = await unwrapSecret(privRaw);
  } catch (_) {
    return null;
  }
  final point = parseP256Spki(pubSpki);
  final keyPair = EcKeyPairData(
    d: privBytes,
    x: point.x,
    y: point.y,
    type: KeyPairType.p256,
  );
  return OneTimePrekeyRecord(
    id: row['id'] as String,
    pubSpki: Uint8List.fromList(pubSpki),
    privateKey: keyPair,
    used: (row['used'] as num?)?.toInt() ?? 0,
    createdAt: (row['createdAt'] as num?)?.toInt() ?? 0,
    usedAt: (row['usedAt'] as num?)?.toInt(),
  );
}

/// Mint [count] fresh OPKs and persist them. Returns their public id/SPKI
/// pairs so the caller can drop them into an outgoing bundle.
Future<List<OneTimePrekey>> generateOneTimePrekeys(
    [int count = _defaultOpkPoolSize]) async {
  final minted = <OneTimePrekey>[];
  final now = DateTime.now().millisecondsSinceEpoch;
  for (var i = 0; i < count; i++) {
    final pair = await _generateEcdhPair();
    final pubSpki = await _exportSpki(pair);
    final privBytes = await _extractPriv(pair);
    final id = _randomId('opk');
    await keyStore().put(_prekeysTable, {
      'id': id,
      'kind': 'opk',
      'status': 'fresh',
      'used': 0,
      'privBytes': await wrapSecret(privBytes),
      'privEnc': 1,
      'pubSpki': pubSpki,
      'createdAt': now,
    });
    minted.add(OneTimePrekey(id: id, pubSpki: pubSpki));
  }
  return minted;
}

Future<int> countFreshOPKs() async {
  final rows = await keyStore()
      .getAll(_prekeysTable, indexField: 'kind', indexValue: 'opk');
  var n = 0;
  for (final r in rows) {
    if ((r['used'] as num?)?.toInt() == 0) n++;
  }
  return n;
}

/// Pull up to [n] fresh OPKs for publication. Does **not** mark used —
/// consumption happens in [consumeOPK] on inbound X3DH.
Future<List<OneTimePrekey>> listFreshOPKs([int n = 20]) async {
  final rows = await keyStore()
      .getAll(_prekeysTable, indexField: 'kind', indexValue: 'opk');
  final out = <OneTimePrekey>[];
  for (final r in rows) {
    if (out.length >= n) break;
    if ((r['used'] as num?)?.toInt() == 0) {
      out.add(OneTimePrekey(
        id: r['id'] as String,
        pubSpki: Uint8List.fromList(r['pubSpki'] as List<int>),
      ));
    }
  }
  return out;
}

/// Load a fresh OPK **without** marking it used. The responder must run
/// X3DH (and any other hello checks) first; [consumeOPK] runs only after
/// that succeeds so a failed handshake cannot burn the pool.
Future<OneTimePrekeyRecord?> peekFreshOPK(String id) async {
  final row = await keyStore().get(_prekeysTable, id);
  if (row == null || row['kind'] != 'opk') return null;
  if ((row['used'] as num?)?.toInt() != 0) return null;
  return _rowToOpk(row);
}

/// Fetch an OPK and mark it used in one step. Returns null if missing or
/// already consumed — a second consume of the same id is a no-op so replays
/// cannot force key reuse.
Future<OneTimePrekeyRecord?> consumeOPK(String id) async {
  final row = await keyStore().get(_prekeysTable, id);
  if (row == null || row['kind'] != 'opk') return null;
  if ((row['used'] as num?)?.toInt() != 0) return null;
  final rec = await _rowToOpk(row);
  if (rec == null) return null;
  await keyStore().put(_prekeysTable, {
    ...row,
    'used': 1,
    'usedAt': DateTime.now().millisecondsSinceEpoch,
  });
  return rec;
}

Future<int> pruneUsedOPKs({int maxAgeMs = _usedOpkRetentionMs}) async {
  final cutoff = DateTime.now().millisecondsSinceEpoch - maxAgeMs;
  final rows = await keyStore()
      .getAll(_prekeysTable, indexField: 'kind', indexValue: 'opk');
  var removed = 0;
  for (final row in rows) {
    if ((row['used'] as num?)?.toInt() == 1) {
      final usedAt = (row['usedAt'] as num?)?.toInt() ?? 0;
      if (usedAt < cutoff) {
        await keyStore().delete(_prekeysTable, row['id'] as String);
        removed++;
      }
    }
  }
  return removed;
}

/// One-shot bootstrap: ensure the SPK isn't stale and top up the OPK pool.
/// Call at startup and whenever the bundle is refreshed.
Future<void> ensurePrekeysReady({
  int rotationMs = _spkRotationMs,
  int targetPool = _defaultOpkPoolSize,
  int minPool = 20,
}) async {
  final active = await getActiveSignedPrekey();
  final now = DateTime.now().millisecondsSinceEpoch;
  final needsRotation = active == null || (now - active.createdAt) > rotationMs;
  if (needsRotation) {
    await rotateSignedPrekey();
  }
  final count = await countFreshOPKs();
  if (count < minPool) {
    await generateOneTimePrekeys(targetPool - count);
  }
}
