// Port of `src/core/db.js` — the high-level app database API.
//
// Everything here talks to the Drift instance returned by [orbitsDb]. The
// method surface mirrors the JS exports 1:1 so UI / business code from
// the React build transplants with minimal diffs:
//
//   saveMessage / getMessages / getPendingMessages          — chat history
//   saveRatchetState / loadRatchetState / deleteRatchetState — crypto state
//   savePeer / getPeer / getAllPeers / deletePeer            — contacts
//   saveAvatar / getAvatar / deleteAvatar                    — profile pics
//   putStickerPack / getAllStickerPacks / deleteStickerPack  — stickers
//   pushRecentSticker / getRecentStickers
//   saveVoiceBlob / getVoiceBlob / deleteVoiceBlob           — audio
//   saveFileBlob  / getFileBlob  / deleteFileBlob            — attachments
//   saveKeyPair / getKeyPair                                 — legacy identity
//   saveSessionKey / getSessionKey / upsertSessionKey / getSessionKeyRecord
//   clearAllMessages / clearPendingMessages / deleteMessagesOlderThan
//   clearAllData                                             — nuke-all
//
// Rows are returned as `Map<String, Object?>` (same as JS) so the call
// sites don't need typed DTOs up front. The UI layer will likely wrap
// these into dataclasses once it lands (Phase 11).

import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../attachments/resumable_blob.dart';
import '../core/path_byte_stream.dart';
import '../core/vault_kek.dart';
import '../utils/common.dart';
import 'database.dart';
import 'row_codec.dart';

// ─── At-rest content encryption (audit L3) ──────────────────────────
//
// Message and peer `data` blobs carry conversation content and contact
// metadata. They're encrypted under the vault KEK before hitting the DB and
// decrypted on read, so the on-disk SQLite / IndexedDB store is opaque without
// the password. Uses the synchronous blob cipher from `vault_kek.dart` (Drift
// row decoders are synchronous). Long-term keys/ratchets are protected
// separately at the field level (audit C2); these helpers cover history.
//
// Migration is lazy and lossless: [_secureDecode] passes a legacy plaintext
// blob straight through (the cipher frame is self-identifying), and the next
// write re-stores it encrypted. Writes while locked throw — they must not
// fall back to plaintext (S-1 / S-2).

Uint8List _secureEncode(Map<String, Object?> row) {
  return wrapBlobSync(encodeRow(row));
}

Uint8List _secureBytesEncode(List<int> plain) => wrapBlobSync(plain);

Uint8List _secureBytesDecode(List<int> stored) => unwrapBlobSync(stored);

/// Decode an encrypted-or-legacy `data` blob. Throws if the blob is encrypted
/// but the vault is locked — callers on one-shot read paths run while unlocked.
Map<String, Object?> _secureDecode(List<int> data) =>
    decodeRow(unwrapBlobSync(data));

/// Null-tolerant variant for `.watch().map` streams — a blob that can't be
/// decrypted (locked vault) or parsed drops out instead of killing the stream.
Map<String, Object?>? _secureDecodeOrNull(List<int> data) {
  try {
    return decodeRow(unwrapBlobSync(data));
  } catch (_) {
    return null;
  }
}

// ─── Constants mirrored from JS ─────────────────────────────────────

const Set<String> _messageStatuses = {
  'pending',
  'sent',
  'delivered',
  'read',
  'failed',
};

/// JS `normalizeMessageStatus` port. Keeps status within the allowed set;
/// falls back to 'delivered' for inbound and 'sent' for outbound when the
/// input is unrecognised.
String _normalizeMessageStatus(Object? status, Object? direction) {
  final s = status?.toString() ?? '';
  if (_messageStatuses.contains(s)) return s;
  return direction == 'in' ? 'delivered' : 'sent';
}

// ─── Double Ratchet snapshots ───────────────────────────────────────

const String _ratchetIdPrefix = 'ratchet-';

String _ratchetRowKey(String peerId) => '$_ratchetIdPrefix$peerId';

/// Persist a Double Ratchet snapshot. `snapshot` must contain a `peerId`
/// string; everything else is serialised verbatim via `row_codec.dart`.
Future<bool> saveRatchetState(Map<String, Object?> snapshot) async {
  final peerId = snapshot['peerId'];
  if (peerId is! String || peerId.isEmpty) return false;
  final row = <String, Object?>{
    'id': _ratchetRowKey(peerId),
    ...snapshot,
  };
  final db = orbitsDb();
  await db.into(db.ratchetsTable).insertOnConflictUpdate(
        RatchetsTableCompanion.insert(
          id: _ratchetRowKey(peerId),
          peerId: peerId,
          // Storage-level encryption (audit Round 5 B.2): ratchet snapshots
          // hold root/chain keys — never touch disk as plaintext JSON.
          data: wrapBlobSync(encodeRow(row)),
        ),
      );
  return true;
}

Future<Map<String, Object?>?> loadRatchetState(String peerId) async {
  if (peerId.isEmpty) return null;
  final db = orbitsDb();
  final row = await (db.select(db.ratchetsTable)
        ..where((t) => t.id.equals(_ratchetRowKey(peerId))))
      .getSingleOrNull();
  return row == null ? null : decodeRow(unwrapBlobSync(row.data));
}

Future<bool> deleteRatchetState(String peerId) async {
  if (peerId.isEmpty) return false;
  final db = orbitsDb();
  await (db.delete(db.ratchetsTable)
        ..where((t) => t.id.equals(_ratchetRowKey(peerId))))
      .go();
  return true;
}

Future<bool> clearAllRatchetState() async {
  await orbitsDb().delete(orbitsDb().ratchetsTable).go();
  return true;
}

// ─── Sticker packs ──────────────────────────────────────────────────

Future<bool> putStickerPack(Map<String, Object?> pack) async {
  final id = (pack['id'] as String?) ?? '';
  if (id.isEmpty) return false;
  final installedAt =
      (pack['installedAt'] as num?)?.toInt() ?? _now();
  final row = <String, Object?>{
    'id': id,
    'name': (pack['name'] as String?) ?? 'Пак',
    'author': pack['author'] ?? 'orbits',
    'thumbnail': pack['thumbnail'],
    'stickers': pack['stickers'] is List ? pack['stickers'] : <Object?>[],
    'installedAt': installedAt,
  };
  final db = orbitsDb();
  await db.into(db.stickerPacksTable).insertOnConflictUpdate(
        StickerPacksTableCompanion.insert(
          id: id,
          installedAt: Value(installedAt),
          data: encodeRow(row),
        ),
      );
  return true;
}

Future<Map<String, Object?>?> getStickerPack(String id) async {
  if (id.isEmpty) return null;
  final db = orbitsDb();
  final row = await (db.select(db.stickerPacksTable)
        ..where((t) => t.id.equals(id)))
      .getSingleOrNull();
  return row == null ? null : decodeRow(row.data);
}

Future<List<Map<String, Object?>>> getAllStickerPacks() async {
  final db = orbitsDb();
  final rows = await (db.select(db.stickerPacksTable)
        ..orderBy([(t) => OrderingTerm.desc(t.installedAt)]))
      .get();
  return rows.map((r) => decodeRow(r.data)).toList();
}

Future<bool> deleteStickerPack(String id) async {
  if (id.isEmpty) return false;
  final db = orbitsDb();
  await (db.delete(db.stickerPacksTable)..where((t) => t.id.equals(id))).go();
  return true;
}

// ─── Recent stickers ────────────────────────────────────────────────

Future<bool> pushRecentSticker(String packId, String stickerId) async {
  final key = '$packId:$stickerId';
  final db = orbitsDb();
  await db.into(db.recentStickersTable).insertOnConflictUpdate(
        RecentStickersTableCompanion.insert(
          key: key,
          packId: packId,
          stickerId: stickerId,
          usedAt: Value(_now()),
        ),
      );
  return true;
}

Future<List<Map<String, Object?>>> getRecentStickers({int limit = 24}) async {
  final db = orbitsDb();
  final rows = await (db.select(db.recentStickersTable)
        ..orderBy([(t) => OrderingTerm.desc(t.usedAt)])
        ..limit(limit))
      .get();
  return rows
      .map((r) => <String, Object?>{
            'key': r.key,
            'packId': r.packId,
            'stickerId': r.stickerId,
            'usedAt': r.usedAt,
          })
      .toList();
}

// ─── Voice messages ─────────────────────────────────────────────────

Future<bool> saveVoiceBlob(
  String id,
  List<int> bytes, {
  String? mime,
  int duration = 0,
  List<double>? waveform,
}) async {
  if (id.isEmpty) return false;
  // Defense-in-depth byte cap (audit finding 4): mirror the send-side raw cap
  // `_maxVoiceRawBytes` (6 MiB). A blob larger than any legitimate voice
  // message is a hostile/buggy peer — refuse rather than bloat the DB / risk
  // an oversized write.
  if (bytes.length > 6 * 1024 * 1024) return false;
  // Waveform is ≤48 normalized amplitudes in 0..1 — matches the JS wire
  // format (`audioRecorder.js` `compressSamples(..., 48)`). Persisting as
  // doubles keeps the player's bar-height math trivial (no scale-guess)
  // and round-trips cleanly through `jsonEncode` / `jsonDecode`.
  final meta = <String, Object?>{
    'waveform': waveform ?? const <double>[],
    'createdAt': _now(),
  };
  final db = orbitsDb();
  await db.into(db.voiceBlobsTable).insertOnConflictUpdate(
        VoiceBlobsTableCompanion.insert(
          id: id,
          mime: Value(mime ?? 'audio/webm'),
          duration: Value(duration),
          createdAt: Value(_now()),
          bytes: _secureBytesEncode(bytes),
          data: encodeRow(meta),
        ),
      );
  return true;
}

Future<Map<String, Object?>?> getVoiceBlob(String id) async {
  if (id.isEmpty) return null;
  final db = orbitsDb();
  final row = await (db.select(db.voiceBlobsTable)
        ..where((t) => t.id.equals(id)))
      .getSingleOrNull();
  if (row == null) return null;
  final meta = decodeRow(row.data);
  // `jsonDecode` returns `List<dynamic>` with element types `int` or
  // `double` depending on whether the original value had a fractional
  // part (e.g. `0` round-trips as `int`, `0.5` as `double`). Coerce to
  // doubles so downstream bar-height calculations can rely on the type.
  final wfRaw = meta['waveform'];
  final waveform = wfRaw is List
      ? <double>[for (final v in wfRaw) if (v is num) v.toDouble()]
      : const <double>[];
  return <String, Object?>{
    'id': row.id,
    'mime': row.mime,
    'duration': row.duration,
    'createdAt': row.createdAt,
    // Output map key is 'blob' (the public contract callers read) even
    // though the Drift column is named `bytes`.
    'blob': _secureBytesDecode(row.bytes),
    'waveform': waveform,
  };
}

Future<bool> deleteVoiceBlob(String id) async {
  if (id.isEmpty) return false;
  final db = orbitsDb();
  await (db.delete(db.voiceBlobsTable)..where((t) => t.id.equals(id))).go();
  return true;
}

// ─── File attachments ───────────────────────────────────────────────

Future<bool> saveFileBlob(
  String id,
  List<int> bytes, {
  String? mime,
  String? name,
  int size = 0,
  String kind = 'file',
  List<int>? thumb,
  int width = 0,
  int height = 0,
  int duration = 0,
}) async {
  if (id.isEmpty) return false;
  // Defense-in-depth byte cap (audit finding 4): mirror the send-side raw cap
  // `_maxFileRawBytes` (12 MiB).
  if (bytes.length > kMaxPeerJsFileRawBytes) return false;
  // JS trims name to 200 chars — keep parity so inbound rows don't diverge.
  final trimmedName = _clipName(name ?? 'file');
  final db = orbitsDb();
  await db.into(db.fileBlobsTable).insertOnConflictUpdate(
        FileBlobsTableCompanion.insert(
          id: id,
          mime: Value(mime ?? 'application/octet-stream'),
          name: Value(trimmedName),
          kind: Value(kind),
          size: Value(size == 0 ? bytes.length : size),
          width: Value(width),
          height: Value(height),
          duration: Value(duration),
          createdAt: Value(_now()),
          bytes: _secureBytesEncode(bytes),
          thumb: thumb == null
              ? const Value.absent()
              : Value(_secureBytesEncode(thumb)),
          data: encodeRow(<String, Object?>{}),
        ),
      );
  return true;
}

/// Native chat attachment: persist a local plaintext path in KEK-wrapped
/// `data`. Drift `bytes` stays an empty wrapped blob — never the file
/// body. Refuses `://` paths.
Future<bool> saveFileBlobFromPath(
  String id,
  String path, {
  String? mime,
  String? name,
  int size = 0,
  String kind = 'file',
  List<int>? thumb,
  int width = 0,
  int height = 0,
  int duration = 0,
}) async {
  if (id.isEmpty) return false;
  final p = path.trim();
  if (p.isEmpty ||
      p.contains('://') ||
      p.contains('fileKey') ||
      p.contains('peerId') ||
      p.contains('opaqueWakeToken')) {
    return false;
  }
  final n = localPathLength(p);
  if (n == null || n <= 0 || n > kMaxNativeAttachBytes) return false;
  final trimmedName = _clipName(name ?? 'file');
  final db = orbitsDb();
  await db.into(db.fileBlobsTable).insertOnConflictUpdate(
        FileBlobsTableCompanion.insert(
          id: id,
          mime: Value(mime ?? 'application/octet-stream'),
          name: Value(trimmedName),
          kind: Value(kind),
          size: Value(size == 0 ? n : size),
          width: Value(width),
          height: Value(height),
          duration: Value(duration),
          createdAt: Value(_now()),
          bytes: _secureBytesEncode(const <int>[]),
          thumb: thumb == null
              ? const Value.absent()
              : Value(_secureBytesEncode(thumb)),
          data: _secureEncode(<String, Object?>{'localPath': p}),
        ),
      );
  return true;
}

Future<Map<String, Object?>?> getFileBlob(String id) async {
  if (id.isEmpty) return null;
  final db = orbitsDb();
  final row = await (db.select(db.fileBlobsTable)
        ..where((t) => t.id.equals(id)))
      .getSingleOrNull();
  if (row == null) return null;
  String? localPath;
  try {
    Map<String, Object?> extra;
    try {
      extra = _secureDecode(row.data);
    } catch (_) {
      extra = decodeRow(row.data);
    }
    final p = extra['localPath'];
    if (p is String &&
        p.isNotEmpty &&
        !p.contains('://') &&
        !p.contains('fileKey') &&
        !p.contains('peerId')) {
      localPath = p;
    }
  } catch (_) {}
  return <String, Object?>{
    'id': row.id,
    'mime': row.mime,
    'name': row.name,
    'size': row.size,
    'kind': row.kind,
    'width': row.width,
    'height': row.height,
    'duration': row.duration,
    'createdAt': row.createdAt,
    // See note in getVoiceBlob — map key stays 'blob' for caller contract.
    'blob': _secureBytesDecode(row.bytes),
    'thumb': row.thumb == null ? null : _secureBytesDecode(row.thumb!),
    if (localPath != null) 'localPath': localPath,
  };
}

Future<bool> deleteFileBlob(String id) async {
  if (id.isEmpty) return false;
  final db = orbitsDb();
  await (db.delete(db.fileBlobsTable)..where((t) => t.id.equals(id))).go();
  return true;
}

// ─── Legacy identity key pair ───────────────────────────────────────
//
// Kept for migration / compatibility with pre-Phase-4 rows. The current
// crypto stack derives identity via `core/identity_key.dart` which uses
// `keys` rows under id='identity-signing'. These helpers target the
// original `local-identity` row the JS build wrote.

Future<bool> saveKeyPair({
  required Object? privateKey,
  required Object? publicKey,
}) async {
  final db = orbitsDb();
  final row = <String, Object?>{
    'id': 'local-identity',
    'privateKey': privateKey,
    'publicKey': publicKey,
    'createdAt': _now(),
  };
  await db.into(db.keysTable).insertOnConflictUpdate(
        KeysTableCompanion.insert(
          id: 'local-identity',
          data: encodeRow(row),
        ),
      );
  return true;
}

Future<Map<String, Object?>?> getKeyPair() async {
  final db = orbitsDb();
  final row = await (db.select(db.keysTable)
        ..where((t) => t.id.equals('local-identity')))
      .getSingleOrNull();
  return row == null ? null : decodeRow(row.data);
}

// ─── Session keys (legacy symmetric) ────────────────────────────────

String _sessionRowId(String peerId) => 'session-$peerId';

Future<bool> saveSessionKey(String peerId, String symmetricKeyB64) async {
  if (peerId.isEmpty) return false;
  final now = _now();
  final row = <String, Object?>{
    'id': _sessionRowId(peerId),
    'peerId': peerId,
    'symmetricKey': symmetricKeyB64,
    'updatedAt': now,
  };
  final db = orbitsDb();
  await db.into(db.sessionKeysTable).insertOnConflictUpdate(
        SessionKeysTableCompanion.insert(
          id: _sessionRowId(peerId),
          peerId: peerId,
          updatedAt: Value(now),
          data: encodeRow(row),
        ),
      );
  return true;
}

Future<String?> getSessionKey(String peerId) async {
  final row = await getSessionKeyRecord(peerId);
  final key = row?['symmetricKey'];
  return key is String ? key : null;
}

Future<bool> upsertSessionKey(String peerId, String symmetricKeyB64) =>
    saveSessionKey(peerId, symmetricKeyB64);

Future<Map<String, Object?>?> getSessionKeyRecord(String peerId) async {
  if (peerId.isEmpty) return null;
  final db = orbitsDb();
  final row = await (db.select(db.sessionKeysTable)
        ..where((t) => t.id.equals(_sessionRowId(peerId))))
      .getSingleOrNull();
  return row == null ? null : decodeRow(row.data);
}

// ─── Peers ──────────────────────────────────────────────────────────

Future<bool> savePeer(Map<String, Object?> peer) async {
  final id = (peer['id'] as String?) ?? '';
  if (id.isEmpty) return false;

  final db = orbitsDb();
  // Merge semantics — partial updates must not wipe existing displayName /
  // pubKey (same as JS). The read-modify-write runs inside a transaction so
  // concurrent callers (markChatRead, setPeerBlocked, an inbound profile
  // packet) can't interleave and clobber each other with a stale merge —
  // e.g. a block flag being overwritten by a profile update that read the
  // row before the block landed (audit M6).
  return db.transaction<bool>(() async {
    final existing = await _getPeerRaw(id);
    final existingMap = existing ?? const <String, Object?>{};

    final nextDisplayName = () {
      final v = peer['displayName'];
      if (v is String && v.isNotEmpty) {
        return v.length > 64 ? v.substring(0, 64) : v;
      }
      return (existingMap['displayName'] as String?) ?? '';
    }();

    // Local-only rename override. Unlike `displayName` (which comes off the
    // remote profile packet and would overwrite user edits every time the
    // peer broadcasts a new profile) `customName` is never touched by the
    // packet router — only by the chat settings sheet. Merge preserves the
    // existing value when the incoming patch doesn't mention it.
    final customName = () {
      final v = peer['customName'];
      if (v is String) {
        return v.length > 64 ? v.substring(0, 64) : v;
      }
      return (existingMap['customName'] as String?) ?? '';
    }();

    final lastSeenAt = (peer['lastSeenAt'] as num?)?.toInt() ??
        (existingMap['lastSeenAt'] as num?)?.toInt() ??
        0;

    // Watermark for unread counts: timestamp of the newest message the user
    // has "seen" (set by `markChatRead`). Inbound messages with a larger
    // timestamp count as unread in the chat list badge.
    final lastReadAt = (peer['lastReadAt'] as num?)?.toInt() ??
        (existingMap['lastReadAt'] as num?)?.toInt() ??
        0;

    final trustedBool = peer['trusted'] == true ||
        existingMap['trusted'] == true ||
        (existingMap['trusted'] is num &&
            (existingMap['trusted'] as num).toInt() == 1);
    final trustedInt = trustedBool ? 1 : 0;

    final trustLevel = (peer['trustLevel'] as num?)?.toInt() ??
        (existingMap['trustLevel'] as num?)?.toInt() ??
        (trustedBool ? 1 : 0);

    // Blocked flag: accept `true` / `1` / `false` / `0` / absent.  Treated
    // like a tri-state merge — if the caller didn't mention `blocked`,
    // preserve the existing value (default `false`).
    final blockedBool = () {
      final v = peer['blocked'];
      if (v == true || v == 1) return true;
      if (v == false || v == 0) return false;
      final ev = existingMap['blocked'];
      if (ev == true || ev == 1) return true;
      return false;
    }();
    final blockedInt = blockedBool ? 1 : 0;

    final addedAt = (existingMap['addedAt'] as num?)?.toInt() ??
        (peer['addedAt'] as num?)?.toInt() ??
        _now();

    final pubKey = peer['pubKey'] ?? existingMap['pubKey'];

    final row = <String, Object?>{
      'id': id,
      'displayName': nextDisplayName,
      'customName': customName,
      'lastSeenAt': lastSeenAt,
      'lastReadAt': lastReadAt,
      'trusted': trustedBool,
      'blocked': blockedBool,
      'pubKey': pubKey,
      'trustLevel': trustLevel,
      'addedAt': addedAt,
    };

    await db.into(db.peersTable).insertOnConflictUpdate(
          PeersTableCompanion.insert(
            id: id,
            displayName: Value(nextDisplayName),
            lastSeenAt: Value(lastSeenAt),
            trusted: Value(trustedInt),
            trustLevel: Value(trustLevel),
            addedAt: Value(addedAt),
            blocked: Value(blockedInt),
            lastReadAt: Value(lastReadAt),
            data: _secureEncode(row),
          ),
        );
    return true;
  });
}

// ─── Chat-settings helpers ──────────────────────────────────────────
//
// Thin wrappers around `savePeer` so call sites don't have to spell out
// the field name every time. All three rely on `savePeer`'s merge
// semantics — a patch that only sets `{'id': …, 'blocked': true}` keeps
// every other field untouched.

/// Flip the block flag on a peer. `true` silences every future inbound
/// packet from them (enforced in `messaging_notifier.pushInbound`) and
/// stops outbound sends from the composer.
Future<bool> setPeerBlocked(String peerId, bool blocked) =>
    savePeer({'id': peerId, 'blocked': blocked});

/// Store a local display-name override that survives remote profile
/// updates. Empty string clears the override — the chat list falls back
/// to the remote `displayName` / the peer id.
Future<bool> setPeerCustomName(String peerId, String customName) =>
    savePeer({'id': peerId, 'customName': customName});

/// Pin the trust level. 0 = unknown, 1 = TOFU (first-use auto), 2 =
/// verified by user. The chat header badge + send path both read off this.
Future<bool> setPeerTrustLevel(String peerId, int level) =>
    savePeer({'id': peerId, 'trustLevel': level});

/// Promote a peer to TOFU trust (level 1) on first verified handshake, but
/// only from `unknown` (0). Never downgrades a user-confirmed `verified` (2)
/// and never re-promotes if the user explicitly reset to unknown after having
/// been ≥1 — we only act when the stored level is exactly 0 (audit H1).
Future<bool> ensurePeerTofuTrust(String peerId) async {
  if (peerId.isEmpty) return false;
  final existing = await getPeer(peerId);
  final cur = (existing?['trustLevel'] as num?)?.toInt() ?? 0;
  if (cur >= 1) return false;
  return setPeerTrustLevel(peerId, 1);
}

/// Mark the chat as "read up to now". Stamps `lastReadAt = now()` so the
/// unread-count query stops counting everything older than this moment.
/// Called by the chat view on mount and whenever a new inbound message
/// arrives while the chat is in focus.
Future<bool> markChatRead(String peerId, {int? at}) =>
    savePeer({'id': peerId, 'lastReadAt': at ?? _now()});

/// Drop every message for a single peer. Used by the chat settings
/// "очистить историю" action. The peer row itself stays — we only nuke
/// the conversation.
Future<int> clearMessagesForPeer(String peerId) async {
  if (peerId.isEmpty) return 0;
  final db = orbitsDb();
  final n = await (db.delete(db.messagesTable)
        ..where((t) => t.peerId.equals(peerId)))
      .go();
  // The just-deleted messages may have owned voice/file blobs — reap them.
  await sweepOrphanBlobs();
  return n;
}

/// Orphan-blob garbage collector. Voice/file blobs are keyed by the owning
/// message id (`voice_blobs.id` / `file_blobs.id` == `messages.id`), so a row
/// whose id no longer appears in `messages` is dead weight bloating the SQLite
/// file. A single `NOT IN (SELECT id FROM messages)` subquery per table sweeps
/// them. Call after chat deletions, message revokes, and once at app start.
Future<void> sweepOrphanBlobs() async {
  final db = orbitsDb();
  await db.transaction(() async {
    await db.customStatement(
      'DELETE FROM voice_blobs WHERE id NOT IN (SELECT id FROM messages)',
    );
    await db.customStatement(
      'DELETE FROM file_blobs WHERE id NOT IN (SELECT id FROM messages)',
    );
  });
}

Future<Map<String, Object?>?> getPeer(String peerId) async => _getPeerRaw(peerId);

Future<List<Map<String, Object?>>> getAllPeers() async {
  final db = orbitsDb();
  final rows = await db.select(db.peersTable).get();
  return rows.map((r) => _secureDecode(r.data)).toList();
}

Future<bool> deletePeer(String peerId) async {
  if (peerId.isEmpty) return false;
  final db = orbitsDb();
  await (db.delete(db.peersTable)..where((t) => t.id.equals(peerId))).go();
  return true;
}

Future<Map<String, Object?>?> _getPeerRaw(String peerId) async {
  if (peerId.isEmpty) return null;
  final db = orbitsDb();
  final row = await (db.select(db.peersTable)..where((t) => t.id.equals(peerId)))
      .getSingleOrNull();
  return row == null ? null : _secureDecode(row.data);
}

// ─── Messages ───────────────────────────────────────────────────────

Future<bool> saveMessage(Map<String, Object?> message) async {
  final peerId = (message['peerId'] as String?) ?? '';
  final ts = (message['timestamp'] as num?)?.toInt() ?? _now();
  final id = (message['id'] as String?) ?? '$peerId-$ts';
  final direction = (message['direction'] as String?) ?? 'out';
  final status = _normalizeMessageStatus(message['status'], direction);

  // Room/channel routing (schema v3). Null for ordinary 1:1 DMs; set for
  // messages that belong to a Discord-style channel so `watchChannelMessages`
  // can page them by `channel_id`.
  final roomId = message['roomId'] as String?;
  final channelId = message['channelId'] as String?;

  final row = <String, Object?>{
    'id': id,
    'peerId': peerId,
    'timestamp': ts,
    'encryptedPayload': message['encryptedPayload'],
    'payload': message['payload'],
    'direction': direction,
    'status': status,
    if (roomId != null) 'roomId': roomId,
    if (channelId != null) 'channelId': channelId,
  };

  final db = orbitsDb();
  final existing = await (db.select(db.messagesTable)
        ..where((t) => t.id.equals(id)))
      .getSingleOrNull();
  if (existing != null) {
    final current = _secureDecode(existing.data);
    final existingRoom = current['roomId'] as String?;
    final existingChannel = current['channelId'] as String?;
    final incomingIsRoom = roomId != null && roomId.isNotEmpty;
    final existingIsRoom = existingRoom != null && existingRoom.isNotEmpty;
    if (incomingIsRoom != existingIsRoom ||
        (incomingIsRoom &&
            (existingRoom != roomId ||
                (channelId != null &&
                    existingChannel != null &&
                    existingChannel != channelId)))) {
      return false;
    }
  }
  await db.into(db.messagesTable).insertOnConflictUpdate(
        MessagesTableCompanion.insert(
          id: id,
          peerId: peerId,
          timestamp: ts,
          direction: direction,
          status: status,
          data: _secureEncode(row),
          roomId: Value(roomId),
          channelId: Value(channelId),
        ),
      );
  return true;
}

/// Room-message IDs live in a separate namespace from DM IDs so a host
/// cannot overwrite a guest's 1:1 row by reusing the same wire id (R07).
String scopedRoomMessageId(String roomId, String rawId) {
  if (rawId.startsWith('room:')) return rawId;
  return 'room:$roomId:$rawId';
}

Future<Map<String, Object?>?> getMessageById(String id) async {
  if (id.isEmpty) return null;
  final db = orbitsDb();
  final row = await (db.select(db.messagesTable)
        ..where((t) => t.id.equals(id)))
      .getSingleOrNull();
  return row == null ? null : _secureDecode(row.data);
}

Future<bool> updateMessage(String id, Map<String, Object?> patch) async {
  if (id.isEmpty) return false;
  final db = orbitsDb();
  return db.transaction(() async {
    final row = await (db.select(db.messagesTable)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return false;
    final current = _secureDecode(row.data);
    final merged = <String, Object?>{...current, ...patch};

    final ts = (merged['timestamp'] as num?)?.toInt() ?? row.timestamp;
    final direction = (merged['direction'] as String?) ?? row.direction;
    final status = _normalizeMessageStatus(merged['status'], direction);
    final peerId = (merged['peerId'] as String?) ?? row.peerId;

    await (db.update(db.messagesTable)..where((t) => t.id.equals(id))).write(
      MessagesTableCompanion(
        peerId: Value(peerId),
        timestamp: Value(ts),
        direction: Value(direction),
        status: Value(status),
        data: Value(_secureEncode(merged)),
      ),
    );
    return true;
  });
}

Future<bool> updateMessageStatus(String id, String status) =>
    updateMessage(id, {'status': status});

Future<int> updateMessageStatusesBatch(
  List<String> ids,
  String status,
) async {
  if (ids.isEmpty) return 0;
  final db = orbitsDb();
  var updated = 0;
  await db.transaction(() async {
    for (final id in ids) {
      if (id.isEmpty) continue;
      final ok = await updateMessage(id, {'status': status});
      if (ok) updated++;
    }
  });
  return updated;
}

Future<int> deleteMessagesOlderThan(int cutoffTimestamp) async {
  if (cutoffTimestamp <= 0) return 0;
  final db = orbitsDb();
  return (db.delete(db.messagesTable)
        ..where((t) => t.timestamp.isSmallerThanValue(cutoffTimestamp)))
      .go();
}

/// Default chat-history retention (audit Round 5 B.4). `90 days` matches the
/// common messenger baseline; there is no UI knob yet — change here to tune.
const Duration defaultRetentionWindow = Duration(days: 90);

/// Periodic storage maintenance (audit Round 5 B.4). Wires up the previously
/// dead `deleteMessagesOlderThan`, reaps blobs orphaned by those deletions,
/// and VACUUMs so the file actually gives the space back.
///
/// Called fire-and-forget from main() on startup; never throws.
Future<void> runRetentionSweep({
  Duration retention = defaultRetentionWindow,
}) async {
  try {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - retention.inMilliseconds;
    if (cutoff > 0) {
      await deleteMessagesOlderThan(cutoff);
    }
    await sweepOrphanBlobs();
    // VACUUM must run outside a transaction — drift's customStatement is
    // autocommit, which is exactly what SQLite requires here.
    await orbitsDb().customStatement('VACUUM;');
  } catch (_) {
    // Maintenance is best-effort; a locked/corrupt DB surfaces elsewhere.
  }
}

/// Unconfirmed outbound statuses that must survive process restart (R06).
const Set<String> kUnconfirmedOutboundStatuses = {
  'pending',
  'inflight',
  'sent',
};

/// Pending / inflight / sent-without-ACK queue. When [peerId] is null,
/// returns up to [limit] oldest unconfirmed outbound rows; otherwise
/// scoped to one peer. `sent` is included because a crash between the
/// status flip and the ACK used to drop the row from retry forever.
Future<List<Map<String, Object?>>> getPendingMessages({
  String? peerId,
  int limit = 200,
}) async {
  final db = orbitsDb();
  final query = db.select(db.messagesTable)
    ..where((t) =>
        t.direction.equals('out') &
        t.status.isIn(kUnconfirmedOutboundStatuses.toList()))
    ..orderBy([(t) => OrderingTerm.asc(t.timestamp)])
    ..limit(limit);
  if (peerId != null && peerId.isNotEmpty) {
    query.where((t) => t.peerId.equals(peerId));
  }
  final rows = await query.get();
  return rows.map((r) => _secureDecode(r.data)).toList();
}

/// After a process restart, demote every outbound `sent`/`inflight` row
/// back to `pending` so the outbox can retry. Returns how many rows moved.
Future<int> recoverUnconfirmedOutbound() async {
  final db = orbitsDb();
  final rows = await (db.select(db.messagesTable)
        ..where((t) =>
            t.direction.equals('out') &
            (t.status.equals('sent') | t.status.equals('inflight'))))
      .get();
  var n = 0;
  for (final row in rows) {
    if (await updateMessageStatus(row.id, 'pending')) n++;
  }
  return n;
}

/// Pending queue for ROOM messages of [roomId] (audit Round 5 A.3). Room
/// outbox rows carry roomId/channelId columns; ordering is oldest-first so a
/// flush replays in original send order.
Future<List<Map<String, Object?>>> getPendingRoomMessages({
  required String roomId,
  int limit = 200,
}) async {
  final db = orbitsDb();
  if (roomId.isEmpty) return const [];
  final rows = await (db.select(db.messagesTable)
        ..where((t) =>
            t.roomId.equals(roomId) &
            t.status.equals('pending') &
            t.direction.equals('out'))
        ..orderBy([(t) => OrderingTerm.asc(t.timestamp)])
        ..limit(limit))
      .get();
  return rows.map((r) => _secureDecode(r.data)).toList();
}

/// Chat paging — `peerId` required. Returns the newest [limit] messages
/// older than [beforeTimestamp] (default: now), ordered newest → oldest
/// (same direction as JS).
Future<List<Map<String, Object?>>> getMessages(
  String peerId, {
  int limit = 50,
  int? beforeTimestamp,
}) async {
  if (peerId.isEmpty) return const [];
  // Max safe integer for a JS double — on web (dart2js) ints are doubles, so
  // `1 << 62` (> 2^53) silently loses precision and the "before" filter
  // misbehaves. 9007199254740991 == 2^53 - 1 round-trips exactly (audit L6).
  final before = beforeTimestamp ?? 9007199254740991;
  final db = orbitsDb();
  final rows = await (db.select(db.messagesTable)
        ..where((t) =>
            t.peerId.equals(peerId) & t.timestamp.isSmallerThanValue(before))
        ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
        ..limit(limit))
      .get();
  return rows.map((r) => _secureDecode(r.data)).toList();
}

Future<bool> deleteMessageRow(String id) async {
  if (id.isEmpty) return true;
  final db = orbitsDb();
  await (db.delete(db.messagesTable)..where((t) => t.id.equals(id))).go();
  // Revoking a message orphans its voice/file blob — sweep it now.
  await sweepOrphanBlobs();
  return true;
}

Future<bool> clearAllMessages() async {
  await orbitsDb().delete(orbitsDb().messagesTable).go();
  return true;
}

Future<int> clearPendingMessages({String? peerId}) async {
  final db = orbitsDb();
  final q = db.delete(db.messagesTable)
    ..where((t) => t.status.equals('pending'));
  if (peerId != null && peerId.isNotEmpty) {
    q.where((t) => t.peerId.equals(peerId));
  }
  return q.go();
}

// ─── Avatars ────────────────────────────────────────────────────────

Future<bool> saveAvatar(String peerId, String avatarDataUrl) async {
  if (peerId.isEmpty) return false;
  // Storage-layer gate (audit M3): an avatar is otherwise unbounded (unlike
  // name/bio, which are clamped) and a peer could push a multi-MB blob to
  // exhaust storage, or a non-image / SVG payload. Reuse the same allowlist +
  // size validator the protocol layer applies, so this is a defense-in-depth
  // backstop for any caller that reaches the DB without pre-validating.
  if (safeAvatarDataUrl(avatarDataUrl) == null) return false;
  final db = orbitsDb();
  final bytes = _secureBytesEncode(utf8.encode(avatarDataUrl));
  await db.into(db.avatarsTable).insertOnConflictUpdate(
        AvatarsTableCompanion.insert(
          peerId: peerId,
          updatedAt: Value(_now()),
          data: bytes,
        ),
      );
  return true;
}

Future<String?> getAvatar(String peerId) async {
  if (peerId.isEmpty) return null;
  final db = orbitsDb();
  final row = await (db.select(db.avatarsTable)
        ..where((t) => t.peerId.equals(peerId)))
      .getSingleOrNull();
  if (row == null) return null;
  try {
    return utf8.decode(_secureBytesDecode(row.data));
  } catch (_) {
    return null;
  }
}

Future<bool> deleteAvatar(String peerId) async {
  if (peerId.isEmpty) return false;
  final db = orbitsDb();
  await (db.delete(db.avatarsTable)..where((t) => t.peerId.equals(peerId)))
      .go();
  return true;
}

// ─── Reactive watches ───────────────────────────────────────────────
//
// Drift turns any `SimpleSelectStatement` into a `Stream` via `.watch()`.
// Each stream fires with the current result set, then again whenever any
// of the tables it depends on changes. These are the subscription
// endpoints Riverpod providers hang off of — the one-shot `Future`
// variants above stay as-is for non-reactive callers.

/// All peers, ordered by most-recently-seen (matches JS contact picker).
Stream<List<Map<String, Object?>>> watchAllPeers() {
  final db = orbitsDb();
  return (db.select(db.peersTable)
        ..orderBy([(t) => OrderingTerm.desc(t.lastSeenAt)]))
      .watch()
      .map((rows) => _decodeRowsSafe(rows.map((r) => r.data)));
}

/// Decode a batch of message/peer `data` blobs, decrypting (audit L3) and
/// dropping any that fail to parse/decrypt rather than throwing out of a
/// stream `.map` (audit L5).
List<Map<String, Object?>> _decodeRowsSafe(Iterable<List<int>> blobs) {
  final out = <Map<String, Object?>>[];
  for (final b in blobs) {
    final m = _secureDecodeOrNull(b);
    if (m != null) out.add(m);
  }
  return out;
}

/// Stream of the newest [limit] messages for [peerId], oldest-first so the
/// UI can append without re-sorting on every tick. Matches the post-load
/// sort in `messageMapper.rowsToSortedUiMessages`.
Stream<List<Map<String, Object?>>> watchMessagesForPeer(
  String peerId, {
  int limit = 50,
}) {
  if (peerId.isEmpty) return Stream.value(const []);
  final db = orbitsDb();
  return (db.select(db.messagesTable)
        ..where((t) => t.peerId.equals(peerId))
        ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
        ..limit(limit))
      .watch()
      .map((rows) {
    // Drift returns newest→oldest; flip so the chat view renders oldest→
    // newest without an extra `.reversed.toList()` in the UI.
    final mapped = _decodeRowsSafe(rows.map((r) => r.data));
    mapped.sort((a, b) {
      final at = (a['timestamp'] as num?)?.toInt() ?? 0;
      final bt = (b['timestamp'] as num?)?.toInt() ?? 0;
      return at - bt;
    });
    return mapped;
  });
}

// ─── Rooms (Discord-style networks, schema v3) ──────────────────────

/// Upsert a room. When the local user is the host (`isHost == true`) and the
/// room has no channels yet, this provisions the two default channels: text
/// `general` (rendered `#general`) and voice `Голосовой 1` (rendered
/// `🔊 Голосовой 1`). The `#` / `🔊` are UI prefixes derived from the channel
/// `type`; stored names are bare. Idempotent — re-saving an existing room
/// (e.g. a status flip) never duplicates channels.
Future<void> saveRoom(Map<String, Object?> room) async {
  final id = (room['id'] as String?) ?? '';
  if (id.isEmpty) return;
  final db = orbitsDb();
  final isHost = room['isHost'] == true ||
      (room['isHost'] is num && (room['isHost'] as num).toInt() != 0);

  await db.into(db.roomsTable).insertOnConflictUpdate(
        RoomsTableCompanion.insert(
          id: id,
          name: Value((room['name'] as String?) ?? ''),
          hostPeerId: Value((room['hostPeerId'] as String?) ?? ''),
          isHost: Value(isHost),
          createdAt: Value((room['createdAt'] as num?)?.toInt() ?? _now()),
          status: Value((room['status'] as String?) ?? 'active'),
        ),
      );

  if (isHost) {
    final existing = await (db.select(db.roomChannelsTable)
          ..where((t) => t.roomId.equals(id))
          ..limit(1))
        .get();
    if (existing.isEmpty) {
      await createChannel(id, 'general', 'text');
      await createChannel(id, 'Голосовой 1', 'voice');
    }
  }
}

/// Create a channel in [roomId]. [type] is 'text' | 'voice'. `position` is the
/// next free slot (current channel count) so channels render in creation
/// order; the id is a fresh UUID v4. Returns the created channel map (id +
/// fields) so the host can broadcast a `room_channel_create` to guests.
Future<Map<String, Object?>> createChannel(
    String roomId, String name, String type) async {
  if (roomId.isEmpty) return const <String, Object?>{};
  final db = orbitsDb();
  final existing = await (db.select(db.roomChannelsTable)
        ..where((t) => t.roomId.equals(roomId)))
      .get();
  final id = _uuidV4();
  final position = existing.length;
  await db.into(db.roomChannelsTable).insert(
        RoomChannelsTableCompanion.insert(
          id: id,
          roomId: roomId,
          name: Value(name),
          type: type,
          position: Value(position),
        ),
      );
  return <String, Object?>{
    'id': id,
    'roomId': roomId,
    'name': name,
    'type': type,
    'position': position,
  };
}

/// All rooms the user hosts or has joined, newest-first. Drives the Discord
/// "server rail". Reactive.
Stream<List<Map<String, Object?>>> watchRooms() {
  final db = orbitsDb();
  return (db.select(db.roomsTable)
        ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
      .watch()
      .map((rows) => rows
          .map((r) => <String, Object?>{
                'id': r.id,
                'name': r.name,
                'hostPeerId': r.hostPeerId,
                'isHost': r.isHost,
                'createdAt': r.createdAt,
                'status': r.status,
              })
          .toList());
}

/// Upsert a room member (composite key {roomId, peerId}). `avatarDataUrl` is
/// an optional inline base64 data-URL for instant roster rendering. Re-saving
/// the same member updates their row (e.g. online/offline, renamed).
Future<void> saveRoomMember(Map<String, Object?> member) async {
  final roomId = (member['roomId'] as String?) ?? '';
  final peerId = (member['peerId'] as String?) ?? '';
  if (roomId.isEmpty || peerId.isEmpty) return;
  final db = orbitsDb();
  final isOnline = member['isOnline'] == true ||
      (member['isOnline'] is num && (member['isOnline'] as num).toInt() != 0);
  await db.into(db.roomMembersTable).insertOnConflictUpdate(
        RoomMembersTableCompanion.insert(
          roomId: roomId,
          peerId: peerId,
          displayName: Value((member['displayName'] as String?) ?? ''),
          avatarDataUrl: Value(member['avatarDataUrl'] as String?),
          isOnline: Value(isOnline),
          joinedAt: Value((member['joinedAt'] as num?)?.toInt() ?? _now()),
        ),
      );
}

/// Delete a room. Foreign keys (`PRAGMA foreign_keys = ON`, set in
/// `database.dart` `beforeOpen`) cascade the delete to the room's channels,
/// members, and — transitively, via `messages.channel_id` — the channels'
/// message history.
Future<bool> deleteRoom(String roomId) async {
  if (roomId.isEmpty) return false;
  final db = orbitsDb();
  await (db.delete(db.roomsTable)..where((t) => t.id.equals(roomId))).go();
  return true;
}

/// Flip a room's `status` ('active' | 'offline'). Used when the host
/// destroys the room (`room_destroy`) — the row is kept (history stays) but
/// marked offline so the UI greys it out.
Future<void> setRoomStatus(String roomId, String status) async {
  if (roomId.isEmpty) return;
  final db = orbitsDb();
  await (db.update(db.roomsTable)..where((t) => t.id.equals(roomId)))
      .write(RoomsTableCompanion(status: Value(status)));
}

/// One-shot channel list for [roomId] (ordered by position). Used by the host
/// to sync the channel set to a joining guest, and to resolve the default
/// channel id after room creation.
Future<List<Map<String, Object?>>> getRoomChannels(String roomId) async {
  if (roomId.isEmpty) return const [];
  final db = orbitsDb();
  final rows = await (db.select(db.roomChannelsTable)
        ..where((t) => t.roomId.equals(roomId))
        ..orderBy([(t) => OrderingTerm.asc(t.position)]))
      .get();
  return rows
      .map((r) => <String, Object?>{
            'id': r.id,
            'roomId': r.roomId,
            'name': r.name,
            'type': r.type,
            'position': r.position,
          })
      .toList();
}

/// Insert-or-update a channel with a CALLER-supplied id. Used by guests to
/// replicate the host's channels (id must match so messages keyed by
/// `channelId` line up across host + guests) — `createChannel` generates a
/// fresh id and is host-only.
Future<void> upsertRoomChannel(Map<String, Object?> channel) async {
  final id = (channel['id'] as String?) ?? '';
  final roomId = (channel['roomId'] as String?) ?? '';
  if (id.isEmpty || roomId.isEmpty) return;
  final db = orbitsDb();
  await db.into(db.roomChannelsTable).insertOnConflictUpdate(
        RoomChannelsTableCompanion.insert(
          id: id,
          roomId: roomId,
          name: Value((channel['name'] as String?) ?? ''),
          type: (channel['type'] as String?) ?? 'text',
          position: Value((channel['position'] as num?)?.toInt() ?? 0),
        ),
      );
}

/// One-shot member roster for [roomId] (ordered by join time). Used by the
/// host to assemble the `room_members_update` broadcast.
Future<List<Map<String, Object?>>> getRoomMembers(String roomId) async {
  if (roomId.isEmpty) return const [];
  final db = orbitsDb();
  final rows = await (db.select(db.roomMembersTable)
        ..where((t) => t.roomId.equals(roomId))
        ..orderBy([(t) => OrderingTerm.asc(t.joinedAt)]))
      .get();
  return rows
      .map((r) => <String, Object?>{
            'roomId': r.roomId,
            'peerId': r.peerId,
            'displayName': r.displayName,
            'avatarDataUrl': r.avatarDataUrl,
            'isOnline': r.isOnline,
            'joinedAt': r.joinedAt,
          })
      .toList();
}

/// Overwrite a room's member roster with [members] in one transaction. Guests
/// call this on `room_members_update` so avatars/names appear instantly and
/// departed members vanish. Each entry accepts `displayName` or `name`.
Future<void> replaceRoomMembers(
  String roomId,
  List<Map<String, Object?>> members,
) async {
  if (roomId.isEmpty) return;
  final db = orbitsDb();
  await db.transaction(() async {
    await (db.delete(db.roomMembersTable)..where((t) => t.roomId.equals(roomId)))
        .go();
    for (final m in members) {
      final peerId = (m['peerId'] as String?) ?? '';
      if (peerId.isEmpty) continue;
      final name =
          (m['displayName'] as String?) ?? (m['name'] as String?) ?? '';
      final isOnline = m['isOnline'] == true ||
          (m['isOnline'] is num && (m['isOnline'] as num).toInt() != 0);
      await db.into(db.roomMembersTable).insertOnConflictUpdate(
            RoomMembersTableCompanion.insert(
              roomId: roomId,
              peerId: peerId,
              displayName: Value(name),
              avatarDataUrl: Value(m['avatarDataUrl'] as String?),
              isOnline: Value(isOnline),
              joinedAt: Value((m['joinedAt'] as num?)?.toInt() ?? _now()),
            ),
          );
    }
  });
}

/// Remove one member from a room (used by the host on `room_leave`).
Future<void> removeRoomMember(String roomId, String peerId) async {
  if (roomId.isEmpty || peerId.isEmpty) return;
  final db = orbitsDb();
  await (db.delete(db.roomMembersTable)
        ..where((t) => t.roomId.equals(roomId) & t.peerId.equals(peerId)))
      .go();
}

/// Channels of [roomId], ordered by `position` (creation order). Reactive.
Stream<List<Map<String, Object?>>> watchChannels(String roomId) {
  if (roomId.isEmpty) return Stream.value(const []);
  final db = orbitsDb();
  return (db.select(db.roomChannelsTable)
        ..where((t) => t.roomId.equals(roomId))
        ..orderBy([(t) => OrderingTerm.asc(t.position)]))
      .watch()
      .map((rows) => rows
          .map((r) => <String, Object?>{
                'id': r.id,
                'roomId': r.roomId,
                'name': r.name,
                'type': r.type,
                'position': r.position,
              })
          .toList());
}

/// Members of [roomId], ordered by join time. Reactive.
Stream<List<Map<String, Object?>>> watchRoomMembers(String roomId) {
  if (roomId.isEmpty) return Stream.value(const []);
  final db = orbitsDb();
  return (db.select(db.roomMembersTable)
        ..where((t) => t.roomId.equals(roomId))
        ..orderBy([(t) => OrderingTerm.asc(t.joinedAt)]))
      .watch()
      .map((rows) => rows
          .map((r) => <String, Object?>{
                'roomId': r.roomId,
                'peerId': r.peerId,
                'displayName': r.displayName,
                'avatarDataUrl': r.avatarDataUrl,
                'isOnline': r.isOnline,
                'joinedAt': r.joinedAt,
              })
          .toList());
}

/// Newest [limit] messages of a channel, oldest-first. Same decode + sort as
/// [watchMessagesForPeer] — the encrypted `data` blob carries the payload.
Stream<List<Map<String, Object?>>> watchChannelMessages(
  String channelId, {
  int limit = 50,
}) {
  if (channelId.isEmpty) return Stream.value(const []);
  final db = orbitsDb();
  return (db.select(db.messagesTable)
        ..where((t) => t.channelId.equals(channelId))
        ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
        ..limit(limit))
      .watch()
      .map((rows) {
    final mapped = _decodeRowsSafe(rows.map((r) => r.data));
    mapped.sort((a, b) {
      final at = (a['timestamp'] as num?)?.toInt() ?? 0;
      final bt = (b['timestamp'] as num?)?.toInt() ?? 0;
      return at - bt;
    });
    return mapped;
  });
}

/// RFC 4122 UUID v4 from a CSPRNG — used for channel ids.
String _uuidV4() {
  final rng = Random.secure();
  final b = List<int>.generate(16, (_) => rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
  String hx(int n) => n.toRadixString(16).padLeft(2, '0');
  final s = b.map(hx).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-'
      '${s.substring(16, 20)}-${s.substring(20)}';
}

/// Pending outbox scoped to a single peer, oldest-first (flush order).
Stream<List<Map<String, Object?>>> watchPendingForPeer(String peerId) {
  if (peerId.isEmpty) return Stream.value(const []);
  final db = orbitsDb();
  return (db.select(db.messagesTable)
        ..where((t) => t.peerId.equals(peerId) & t.status.equals('pending'))
        ..orderBy([(t) => OrderingTerm.asc(t.timestamp)]))
      .watch()
      .map((rows) => _decodeRowsSafe(rows.map((r) => r.data)));
}

/// Global pending queue across all peers, oldest-first. Used by the
/// reconnect-time flush path (`flushAllOutbox`). [limit] keeps huge
/// backlogs from spamming the subscriber on first emit.
Stream<List<Map<String, Object?>>> watchPendingGlobal({int limit = 500}) {
  final db = orbitsDb();
  return (db.select(db.messagesTable)
        ..where((t) => t.status.equals('pending'))
        ..orderBy([(t) => OrderingTerm.asc(t.timestamp)])
        ..limit(limit))
      .watch()
      .map((rows) => _decodeRowsSafe(rows.map((r) => r.data)));
}

/// Per-peer chat metadata for the chat list: newest message blob, its
/// timestamp, and the number of inbound messages newer than the peer's
/// `lastReadAt` watermark. Emits one row for every peer that has at least
/// one message row — peers with an empty history are filtered out here
/// and stitched back in by [chatListProvider] so the list still shows
/// "empty" placeholders where the user added a contact but never chatted.
///
/// Custom SQL because the chat list needs:
///   1. the latest message per peer (correlated subquery — no window fns in
///      SQLite < 3.25 on older Android targets),
///   2. an aggregate unread count in the same round trip.
///
/// `readsFrom` lists both `messages` and `peers` so the stream re-emits
/// when `markChatRead` bumps a watermark — Drift otherwise only refires
/// on the primary FROM table.
Stream<List<Map<String, Object?>>> watchChatMetas() {
  final db = orbitsDb();
  // NB: raw SQL must use drift's snake_case SQL column names (peer_id,
  // last_read_at), not the camelCase Dart getters — the output aliases
  // (peerId/lastTs/…) are arbitrary and read back by those names below.
  final query = db.customSelect(
    '''
    SELECT
      m.peer_id AS peerId,
      MAX(m.timestamp) AS lastTs,
      (
        SELECT data FROM messages
        WHERE peer_id = m.peer_id
        ORDER BY timestamp DESC
        LIMIT 1
      ) AS lastData,
      SUM(CASE
        WHEN m.direction = 'in'
             AND m.timestamp > IFNULL(p.last_read_at, 0)
        THEN 1 ELSE 0
      END) AS unreadCount
    FROM messages m
    LEFT JOIN peers p ON p.id = m.peer_id
    GROUP BY m.peer_id
    ''',
    readsFrom: {db.messagesTable, db.peersTable},
  );

  return query.watch().map((rows) => rows.map((r) {
        final lastDataBlob = r.readNullable<Uint8List>('lastData');
        final lastData =
            lastDataBlob == null ? null : _secureDecodeOrNull(lastDataBlob);
        return <String, Object?>{
          'peerId': r.read<String>('peerId'),
          'lastTs': r.readNullable<int>('lastTs') ?? 0,
          'lastData': lastData,
          'unreadCount': r.readNullable<int>('unreadCount') ?? 0,
        };
      }).toList());
}

// ─── Nuke ────────────────────────────────────────────────────────────

/// Full local wipe — removes **every** persisted store in one transaction,
/// including the long-term identity keys (`keys`), all signed/one-time
/// prekeys (`prekeys`), TOFU pins (also in `keys`), ratchet snapshots, and the
/// `kv` table that holds the auth token + its HMAC signing key.
///
/// This is the "reset profile" / forgot-password path. Earlier this method
/// claimed to leave identity/prekeys intact but actually deleted `keys` while
/// skipping `prekeys` and `kv` — leaving private prekeys and a reusable auth
/// token behind after a supposed full reset (audit H4). It now wipes
/// everything consistently. Use only when the caller really wants a clean
/// slate; `logout()` keeps the identity for re-onboarding.
Future<bool> clearAllData() async {
  final db = orbitsDb();
  await db.transaction(() async {
    await db.delete(db.peersTable).go();
    await db.delete(db.messagesTable).go();
    await db.delete(db.keysTable).go();
    await db.delete(db.prekeysTable).go();
    await db.delete(db.sessionKeysTable).go();
    await db.delete(db.avatarsTable).go();
    await db.delete(db.stickerPacksTable).go();
    await db.delete(db.recentStickersTable).go();
    await db.delete(db.voiceBlobsTable).go();
    await db.delete(db.fileBlobsTable).go();
    await db.delete(db.ratchetsTable).go();
    await db.delete(db.kvTable).go();
    // Rooms (schema v3). Children first; FK CASCADE would also reap them, but
    // explicit deletes keep the wipe correct even if FK enforcement is off.
    await db.delete(db.roomMembersTable).go();
    await db.delete(db.roomChannelsTable).go();
    await db.delete(db.roomsTable).go();
  });
  return true;
}

// ─── Helpers ────────────────────────────────────────────────────────

int _now() => DateTime.now().millisecondsSinceEpoch;

String _clipName(String name) =>
    name.length > 200 ? name.substring(0, 200) : name;
