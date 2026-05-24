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
import 'dart:typed_data';

import 'package:drift/drift.dart';

import 'database.dart';
import 'row_codec.dart';
import 'tables.dart';

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
          data: encodeRow(row),
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
  return row == null ? null : decodeRow(row.data);
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
          bytes: Uint8List.fromList(bytes),
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
    'blob': row.bytes,
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
          bytes: Uint8List.fromList(bytes),
          thumb:
              thumb == null ? const Value.absent() : Value(Uint8List.fromList(thumb)),
          data: encodeRow(<String, Object?>{}),
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
    'blob': row.bytes,
    'thumb': row.thumb,
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
  // Merge semantics — partial updates must not wipe existing displayName / pubKey
  // (same as JS).
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
          data: encodeRow(row),
        ),
      );
  return true;
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
  return (db.delete(db.messagesTable)..where((t) => t.peerId.equals(peerId)))
      .go();
}

Future<Map<String, Object?>?> getPeer(String peerId) async => _getPeerRaw(peerId);

Future<List<Map<String, Object?>>> getAllPeers() async {
  final db = orbitsDb();
  final rows = await db.select(db.peersTable).get();
  return rows.map((r) => decodeRow(r.data)).toList();
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
  return row == null ? null : decodeRow(row.data);
}

// ─── Messages ───────────────────────────────────────────────────────

Future<bool> saveMessage(Map<String, Object?> message) async {
  final peerId = (message['peerId'] as String?) ?? '';
  final ts = (message['timestamp'] as num?)?.toInt() ?? _now();
  final id = (message['id'] as String?) ?? '$peerId-$ts';
  final direction = (message['direction'] as String?) ?? 'out';
  final status = _normalizeMessageStatus(message['status'], direction);

  final row = <String, Object?>{
    'id': id,
    'peerId': peerId,
    'timestamp': ts,
    'encryptedPayload': message['encryptedPayload'],
    'payload': message['payload'],
    'direction': direction,
    'status': status,
  };

  final db = orbitsDb();
  await db.into(db.messagesTable).insertOnConflictUpdate(
        MessagesTableCompanion.insert(
          id: id,
          peerId: peerId,
          timestamp: ts,
          direction: direction,
          status: status,
          data: encodeRow(row),
        ),
      );
  return true;
}

Future<Map<String, Object?>?> getMessageById(String id) async {
  if (id.isEmpty) return null;
  final db = orbitsDb();
  final row = await (db.select(db.messagesTable)
        ..where((t) => t.id.equals(id)))
      .getSingleOrNull();
  return row == null ? null : decodeRow(row.data);
}

Future<bool> updateMessage(String id, Map<String, Object?> patch) async {
  if (id.isEmpty) return false;
  final db = orbitsDb();
  return db.transaction(() async {
    final row = await (db.select(db.messagesTable)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return false;
    final current = decodeRow(row.data);
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
        data: Value(encodeRow(merged)),
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

/// Pending queue. When [peerId] is null, returns up to [limit] oldest
/// pending messages across all peers; otherwise scoped to one peer.
Future<List<Map<String, Object?>>> getPendingMessages({
  String? peerId,
  int limit = 200,
}) async {
  final db = orbitsDb();
  final query = db.select(db.messagesTable)
    ..where((t) => t.status.equals('pending'))
    ..orderBy([(t) => OrderingTerm.asc(t.timestamp)])
    ..limit(limit);
  if (peerId != null && peerId.isNotEmpty) {
    query.where((t) => t.peerId.equals(peerId));
  }
  final rows = await query.get();
  return rows.map((r) => decodeRow(r.data)).toList();
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
  // Web (dart2js/dart2wasm) evaluates `<<` with 32-bit semantics, so
  // `1 << 62` collapses to a tiny value and would exclude every real
  // ms-epoch message. Use a literal that's web-safe (≤ 2^53-1) yet far above
  // any plausible timestamp.
  const maxTimestampSentinel = 9007199254740991; // 2^53 - 1
  final before = beforeTimestamp ?? maxTimestampSentinel;
  final db = orbitsDb();
  final rows = await (db.select(db.messagesTable)
        ..where((t) =>
            t.peerId.equals(peerId) & t.timestamp.isSmallerThanValue(before))
        ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
        ..limit(limit))
      .get();
  return rows.map((r) => decodeRow(r.data)).toList();
}

Future<bool> deleteMessageRow(String id) async {
  if (id.isEmpty) return true;
  final db = orbitsDb();
  await (db.delete(db.messagesTable)..where((t) => t.id.equals(id))).go();
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
  final db = orbitsDb();
  final bytes = Uint8List.fromList(utf8.encode(avatarDataUrl));
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
    return utf8.decode(row.data);
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
      .map((rows) => rows.map((r) => decodeRow(r.data)).toList());
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
    final mapped = rows.map((r) => decodeRow(r.data)).toList();
    mapped.sort((a, b) {
      final at = (a['timestamp'] as num?)?.toInt() ?? 0;
      final bt = (b['timestamp'] as num?)?.toInt() ?? 0;
      return at - bt;
    });
    return mapped;
  });
}

/// Pending outbox scoped to a single peer, oldest-first (flush order).
Stream<List<Map<String, Object?>>> watchPendingForPeer(String peerId) {
  if (peerId.isEmpty) return Stream.value(const []);
  final db = orbitsDb();
  return (db.select(db.messagesTable)
        ..where((t) => t.peerId.equals(peerId) & t.status.equals('pending'))
        ..orderBy([(t) => OrderingTerm.asc(t.timestamp)]))
      .watch()
      .map((rows) => rows.map((r) => decodeRow(r.data)).toList());
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
      .map((rows) => rows.map((r) => decodeRow(r.data)).toList());
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
            lastDataBlob == null ? null : decodeRow(lastDataBlob);
        return <String, Object?>{
          'peerId': r.read<String>('peerId'),
          'lastTs': r.readNullable<int>('lastTs') ?? 0,
          'lastData': lastData,
          'unreadCount': r.readNullable<int>('unreadCount') ?? 0,
        };
      }).toList());
}

// ─── Nuke ────────────────────────────────────────────────────────────

/// Clear every user-owned store. Identity / prekeys are intentionally
/// left intact — matching JS, which wiped `peers`/`messages`/`keys` etc.
/// as a single atomic "debug reset" without touching ratchet keys.
Future<bool> clearAllData() async {
  final db = orbitsDb();
  await db.transaction(() async {
    await db.delete(db.peersTable).go();
    await db.delete(db.messagesTable).go();
    await db.delete(db.keysTable).go();
    await db.delete(db.sessionKeysTable).go();
    await db.delete(db.avatarsTable).go();
    await db.delete(db.stickerPacksTable).go();
    await db.delete(db.recentStickersTable).go();
    await db.delete(db.voiceBlobsTable).go();
    await db.delete(db.fileBlobsTable).go();
    await db.delete(db.ratchetsTable).go();
  });
  return true;
}

// ─── Helpers ────────────────────────────────────────────────────────

int _now() => DateTime.now().millisecondsSinceEpoch;

String _clipName(String name) =>
    name.length > 200 ? name.substring(0, 200) : name;
