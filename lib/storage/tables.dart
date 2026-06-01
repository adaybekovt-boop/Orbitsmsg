// Drift schema mirroring the JS IndexedDB database (`src/core/db.js`).
//
// Each JS object-store becomes a Drift table below. Heterogeneous per-row
// payloads stay as a single JSON blob in `data` (encoded via
// `row_codec.dart`); any field the app needs to index or filter on gets
// promoted to its own column so SQLite can hit it with a B-tree.
//
// Table ↔ store map:
//
//   KeysTable            → 'keys'            (identity, peer pins, bundles)
//   PrekeysTable         → 'prekeys'         (X3DH SPK + OPK pool)
//   RatchetsTable        → 'ratchet_state'   (Double Ratchet snapshots)
//   PeersTable           → 'peers'           (contact list)
//   AvatarsTable         → 'avatars'         (peer profile pictures)
//   SessionKeysTable     → 'session_keys'    (legacy symmetric sessions)
//   MessagesTable        → 'messages'        (encrypted chat history)
//   StickerPacksTable    → 'sticker_packs'
//   RecentStickersTable  → 'recent_stickers'
//   VoiceBlobsTable      → 'voice_blobs'     (audio payloads split off msg)
//   FileBlobsTable       → 'file_blobs'      (image/video/doc payloads)
//   KvTable              → 'kv'              (idb_store.dart — auth tokens)

import 'package:drift/drift.dart';

// ─── Crypto core ────────────────────────────────────────────────────

/// Catch-all key/value store. Matches the JS `keys` object-store; used for
/// identity keys, X3DH ephemerals, peer pins and cached prekey bundles.
@DataClassName('KeyRow')
class KeysTable extends Table {
  @override
  String get tableName => 'keys';

  TextColumn get id => text()();
  BlobColumn get data => blob()();

  @override
  Set<Column> get primaryKey => {id};
}

/// X3DH signed + one-time prekey pool. `kind` is 'spk' | 'opk'; `used` is
/// 0/1 — identical to the JS row shape so the crypto modules port straight
/// across.
@DataClassName('PrekeyRow')
class PrekeysTable extends Table {
  @override
  String get tableName => 'prekeys';

  TextColumn get id => text()();
  TextColumn get kind => text().withLength(min: 1, max: 8)();
  IntColumn get used => integer().withDefault(const Constant(0))();
  BlobColumn get data => blob()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Double Ratchet snapshots, one per peer. Row id is `ratchet-<peerId>`
/// (Dart convention); `peerId` is also promoted so future per-peer queries
/// don't need to strip the prefix.
@DataClassName('RatchetRow')
class RatchetsTable extends Table {
  @override
  String get tableName => 'ratchets';

  TextColumn get id => text()();
  TextColumn get peerId => text()();
  BlobColumn get data => blob()();

  @override
  Set<Column> get primaryKey => {id};
}

// ─── Contacts / chat ────────────────────────────────────────────────

/// Contact list. Columns promoted for the common JS indexes
/// (`trusted`, `lastSeenAt`) so the peer picker can sort / filter without
/// scanning every row.
///
/// `blocked` + `lastReadAt` were promoted in schema v2 (Day 2) so the chat
/// list can JOIN against them for unread-count + blocked-filter queries
/// without having to crack open each `data` blob. The fields are still
/// duplicated into the JSON payload on write so `decodeRow()` readers keep
/// seeing them — same pattern `lastSeenAt` / `trustLevel` already follow.
@DataClassName('PeerRow')
class PeersTable extends Table {
  @override
  String get tableName => 'peers';

  TextColumn get id => text()();
  TextColumn get displayName => text().withDefault(const Constant(''))();
  IntColumn get lastSeenAt => integer().withDefault(const Constant(0))();
  IntColumn get trusted => integer().withDefault(const Constant(0))();
  IntColumn get trustLevel => integer().withDefault(const Constant(0))();
  IntColumn get addedAt => integer().withDefault(const Constant(0))();
  IntColumn get blocked => integer().withDefault(const Constant(0))();
  IntColumn get lastReadAt => integer().withDefault(const Constant(0))();
  BlobColumn get data => blob()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Peer avatars (data-URL strings — small PNG/JPEG). PK mirrors JS where
/// `keyPath: 'peerId'`.
@DataClassName('AvatarRow')
class AvatarsTable extends Table {
  @override
  String get tableName => 'avatars';

  TextColumn get peerId => text()();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();
  BlobColumn get data => blob()();

  @override
  Set<Column> get primaryKey => {peerId};
}

/// Legacy static-key symmetric session records. Kept for compatibility —
/// new sessions go through `ratchets`. Row id is `session-<peerId>`.
@DataClassName('SessionKeyRow')
class SessionKeysTable extends Table {
  @override
  String get tableName => 'session_keys';

  TextColumn get id => text()();
  TextColumn get peerId => text()();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();
  BlobColumn get data => blob()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Encrypted messages. The plaintext never lands here — `data` holds the
/// post-ratchet ciphertext + metadata. Direction / status / timestamp are
/// promoted so queues (`pending`/`failed`) and chat paging can hit indexes.
///
/// Composite indexes (created in `database.dart`) mirror the JS ones:
///   - (peerId, timestamp)                   chat paging
///   - (peerId, status, timestamp)           pending-per-peer queue
///   - (status, timestamp)                   global pending queue
@DataClassName('MessageRow')
class MessagesTable extends Table {
  @override
  String get tableName => 'messages';

  TextColumn get id => text()();
  TextColumn get peerId => text()();
  IntColumn get timestamp => integer()();
  TextColumn get direction => text().withLength(min: 2, max: 4)();
  TextColumn get status => text().withLength(min: 1, max: 16)();
  BlobColumn get data => blob()();

  /// Room/channel routing (schema v3 — Discord-style rooms). Both nullable: a
  /// 1:1 DM message leaves them null; a room message carries its owning room +
  /// channel. `channelId` references [RoomChannelsTable] with CASCADE so
  /// deleting a channel reaps its message history. A composite index on
  /// (channel_id, timestamp) is created in `database.dart` for fast per-channel
  /// paging.
  TextColumn get roomId => text().nullable()();
  TextColumn get channelId => text()
      .nullable()
      .references(RoomChannelsTable, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {id};
}

// ─── Stickers ───────────────────────────────────────────────────────

@DataClassName('StickerPackRow')
class StickerPacksTable extends Table {
  @override
  String get tableName => 'sticker_packs';

  TextColumn get id => text()();
  IntColumn get installedAt => integer().withDefault(const Constant(0))();
  BlobColumn get data => blob()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('RecentStickerRow')
class RecentStickersTable extends Table {
  @override
  String get tableName => 'recent_stickers';

  /// `<packId>:<stickerId>` — mirrors JS.
  TextColumn get key => text()();
  TextColumn get packId => text()();
  TextColumn get stickerId => text()();
  IntColumn get usedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {key};
}

// ─── Media blobs ────────────────────────────────────────────────────

/// Voice messages — split off `messages` so deleting a chat's text history
/// doesn't take the audio with it (and vice versa).
@DataClassName('VoiceBlobRow')
class VoiceBlobsTable extends Table {
  @override
  String get tableName => 'voice_blobs';

  TextColumn get id => text()();
  TextColumn get mime => text().withDefault(const Constant('audio/webm'))();
  IntColumn get duration => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  /// Raw audio bytes — encrypted at the application layer before landing.
  /// Column getter is `bytes` (not `blob`) because Drift's `Table` base
  /// class exposes a `blob()` column-builder — a member named `blob` would
  /// shadow it and the analyzer refuses to compile.
  BlobColumn get bytes => blob()();

  /// `{waveform: List<int>, …}` — lightweight metadata JSON.
  BlobColumn get data => blob()();

  @override
  Set<Column> get primaryKey => {id};
}

/// File attachments (images / videos / documents).
@DataClassName('FileBlobRow')
class FileBlobsTable extends Table {
  @override
  String get tableName => 'file_blobs';

  TextColumn get id => text()();
  TextColumn get mime =>
      text().withDefault(const Constant('application/octet-stream'))();
  TextColumn get name => text().withDefault(const Constant('file'))();
  TextColumn get kind => text().withDefault(const Constant('file'))();
  IntColumn get size => integer().withDefault(const Constant(0))();
  IntColumn get width => integer().withDefault(const Constant(0))();
  IntColumn get height => integer().withDefault(const Constant(0))();
  IntColumn get duration => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  /// Encrypted payload bytes. See note on [VoiceBlobsTable.bytes] for why
  /// the getter is `bytes`, not `blob`.
  BlobColumn get bytes => blob()();

  /// Thumbnail blob (nullable — documents won't have one).
  BlobColumn get thumb => blob().nullable()();

  /// Everything else (e.g. origin url) as JSON.
  BlobColumn get data => blob()();

  @override
  Set<Column> get primaryKey => {id};
}

// ─── Rooms (temporary private Discord-style networks, schema v3) ─────
//
// A "room" is a peer-to-peer network with multiple channels (text + voice)
// and a member roster. The host owns the canonical room; joiners mirror it.
// All three tables cascade off the room so tearing a room down (or a channel)
// reaps its children + message history in one delete.

/// A room ("network"). `id` is the shareable code (e.g. 'ORBIT-XXXX-YYYY').
@DataClassName('RoomRow')
class RoomsTable extends Table {
  @override
  String get tableName => 'rooms';

  TextColumn get id => text()();
  TextColumn get name => text().withDefault(const Constant(''))();
  TextColumn get hostPeerId => text().withDefault(const Constant(''))();
  BoolColumn get isHost => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  /// 'active' | 'offline'.
  TextColumn get status => text().withDefault(const Constant('active'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// A channel inside a room. `type` is 'text' | 'voice'. The displayed
/// `#` (text) / `🔊` (voice) prefix is a UI decoration derived from `type` —
/// the stored `name` is bare (e.g. 'general', 'Голосовой 1'). Cascades off
/// the room.
@DataClassName('RoomChannelRow')
class RoomChannelsTable extends Table {
  @override
  String get tableName => 'room_channels';

  TextColumn get id => text()(); // UUID v4
  TextColumn get roomId =>
      text().references(RoomsTable, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text().withDefault(const Constant(''))();
  TextColumn get type => text().withLength(min: 1, max: 8)();
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// A room member. `avatarDataUrl` is an inline base64 data-URL so the roster
/// renders instantly without a second fetch. Composite PK {roomId, peerId} —
/// one row per member per room. Cascades off the room.
@DataClassName('RoomMemberRow')
class RoomMembersTable extends Table {
  @override
  String get tableName => 'room_members';

  TextColumn get roomId =>
      text().references(RoomsTable, #id, onDelete: KeyAction.cascade)();
  TextColumn get peerId => text()();
  TextColumn get displayName => text().withDefault(const Constant(''))();
  TextColumn get avatarDataUrl => text().nullable()();
  BoolColumn get isOnline => boolean().withDefault(const Constant(false))();
  IntColumn get joinedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {roomId, peerId};
}

// ─── Generic KV (idb_store.dart backing) ────────────────────────────

/// Key/value store that backs `idb_store.dart` — used for auth tokens and
/// other small opaque records the JS side kept in a dedicated IndexedDB.
@DataClassName('KvRow')
class KvTable extends Table {
  @override
  String get tableName => 'kv';

  TextColumn get key => text()();
  BlobColumn get value => blob()();

  @override
  Set<Column> get primaryKey => {key};
}
