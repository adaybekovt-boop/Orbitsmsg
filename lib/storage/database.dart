// Drift database aggregator.
//
// Generates `database.g.dart` via build_runner:
//   dart run build_runner build --delete-conflicting-outputs
//
// Until codegen has run at least once the `_$OrbitsDatabase` base class
// below is undefined — that's expected, not a typo. Drift docs:
// https://drift.simonbinder.eu/setup/.

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'db_cipher_opener_stub.dart'
    if (dart.library.io) 'db_cipher_opener_io.dart';
import 'tables.dart';

part 'database.g.dart';

/// Single SQLite file under the app-support directory. Holds every piece
/// of on-disk state — crypto (identity / prekeys / ratchets) + contacts /
/// chats / messages / media / auth kv.
@DriftDatabase(tables: [
  KeysTable,
  PrekeysTable,
  RatchetsTable,
  PeersTable,
  AvatarsTable,
  SessionKeysTable,
  MessagesTable,
  StickerPacksTable,
  RecentStickersTable,
  VoiceBlobsTable,
  FileBlobsTable,
  KvTable,
  RoomsTable,
  RoomChannelsTable,
  RoomMembersTable,
])
class OrbitsDatabase extends _$OrbitsDatabase {
  OrbitsDatabase() : super(_open());

  /// Escape hatch for tests — pass `NativeDatabase.memory()` to stay
  /// off-disk.
  OrbitsDatabase.forTesting(super.e);

  // Schema history:
  //   v1 — initial port of the JS IndexedDB shape.
  //   v2 — Day 2: promoted `blocked` + `lastReadAt` to their own columns on
  //        the peers table so the chat list can JOIN for unread counts and
  //        block-filtering instead of cracking every `data` blob.
  //   v3 — Rooms: rooms / room_channels / room_members tables for the
  //        Discord-style multi-channel networks, plus nullable room_id +
  //        channel_id routing columns on messages.
  @override
  int get schemaVersion => 3;

  /// Indexes we need on top of the primary key. Drift generates the
  /// primary-key B-tree automatically; everything else goes here so the
  /// schema stays explicit.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();

          // Prekey pool: OPK consumers scan `kind='opk' AND used=0`.
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_prekeys_kind_used '
            'ON prekeys(kind, used)',
          );

          // Peer list: contact picker sorts by last_seen_at DESC, and
          // "trusted" filters to verified peers first.
          // NB: column names are drift's snake_case SQL names (the Dart
          // getters are camelCase), so the raw DDL must use them verbatim —
          // SQLite would otherwise reject onCreate with "no such column".
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_peers_last_seen '
            'ON peers(last_seen_at)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_peers_trusted '
            'ON peers(trusted)',
          );

          // Chat paging: `WHERE peer_id=? ORDER BY timestamp DESC`.
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_messages_peer_ts '
            'ON messages(peer_id, timestamp)',
          );

          // Pending queue per peer: `WHERE peer_id=? AND status='pending'`.
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_messages_peer_status_ts '
            'ON messages(peer_id, status, timestamp)',
          );

          // Global pending queue.
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_messages_status_ts '
            'ON messages(status, timestamp)',
          );

          // Sticker pack list ordering.
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_sticker_packs_installed '
            'ON sticker_packs(installed_at)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_recent_stickers_used '
            'ON recent_stickers(used_at)',
          );

          // Rooms (v3): per-channel message paging + per-room child lookups.
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_messages_channel_ts '
            'ON messages(channel_id, timestamp)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_room_channels_room '
            'ON room_channels(room_id, position)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_room_members_room '
            'ON room_members(room_id, joined_at)',
          );
        },
        onUpgrade: (Migrator m, int from, int to) async {
          if (from < 2) {
            // Day 2: add `blocked` + `lastReadAt` to the peers table. Drift's
            // `addColumn` emits `ALTER TABLE peers ADD COLUMN …` with the
            // default from the schema definition, so existing rows land with
            // `blocked=0` + `lastReadAt=0` — i.e. everyone starts unblocked
            // and "everything is unread" the first time the app boots on v2.
            // The first `markChatRead` the user triggers by opening a chat
            // will pin that peer's watermark.
            await m.addColumn(peersTable, peersTable.blocked);
            await m.addColumn(peersTable, peersTable.lastReadAt);
          }
          if (from < 3) {
            // v3: Discord-style rooms. Create the new tables first (rooms
            // before its children so the cascade FKs resolve), then add the
            // nullable routing columns to messages — `channel_id` references
            // room_channels, so that table must already exist — then the
            // per-channel paging index + per-room child indexes.
            await m.createTable(roomsTable);
            await m.createTable(roomChannelsTable);
            await m.createTable(roomMembersTable);
            await m.addColumn(messagesTable, messagesTable.roomId);
            await m.addColumn(messagesTable, messagesTable.channelId);
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_messages_channel_ts '
              'ON messages(channel_id, timestamp)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_room_channels_room '
              'ON room_channels(room_id, position)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_room_members_room '
              'ON room_members(room_id, joined_at)',
            );
          }
        },
        beforeOpen: (details) async {
          // Foreign-key enforcement defaults to OFF in SQLite; turn on
          // so future `REFERENCES` columns behave as declared.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}

/// Open the on-disk database.
///
/// ── SQLCipher full-file encryption (task 5) ──
/// On native platforms the DB is opened through [openCipherExecutor]
/// (`db_cipher_opener_io.dart`), which runs `NativeDatabase.createInBackground`
/// with `PRAGMA key = '<hkdf-derived hex>'` so the whole SQLite file is
/// encrypted at rest by SQLCipher. The key is derived via HKDF-SHA256 (salt
/// `'orbits-sqlite-key'`, see [deriveSqlcipherKeyHex]) from a 32-byte device
/// key held in `flutter_secure_storage`.
///
/// Why a device key and not the vault KEK: the peerId/identity is shown during
/// onboarding BEFORE the password is set, so the identity row must be readable
/// before any password-derived KEK exists — there is simply no KEK available
/// when this DB is first opened at bootstrap, and keying off it would deadlock
/// startup. The device key is always available, so encryption is transparent.
///
/// To stay non-destructive, encryption only applies to a freshly-created DB
/// (tracked by a secure-storage marker); a pre-existing plaintext file is
/// opened as-is (its rows are still vault-encrypted). On web, [openCipherExecutor]
/// returns null and we fall back to the wasm executor (unencrypted container).
///
/// NOTE: enabling SQLCipher on native requires `sqlcipher_flutter_libs` to
/// override `sqlite3_flutter_libs` so the loaded sqlite3 understands
/// `PRAGMA key` — verify the override per platform when wiring native builds.
QueryExecutor _open() {
  final cipher = openCipherExecutor();
  if (cipher != null) return cipher;
  return driftDatabase(
    name: 'orbits',
    native: const DriftNativeOptions(
      shareAcrossIsolates: true,
    ),
    web: DriftWebOptions(
      sqlite3Wasm: Uri.parse('sqlite3.wasm'),
      driftWorker: Uri.parse('drift_worker.js'),
    ),
  );
}

// ─── Process-wide handle ────────────────────────────────────────────

OrbitsDatabase? _singleton;

/// Returns the app-wide database instance, lazily opening it on first
/// access. Tests can override via [setOrbitsDatabase].
OrbitsDatabase orbitsDb() => _singleton ??= OrbitsDatabase();

void setOrbitsDatabase(OrbitsDatabase db) {
  _singleton = db;
}

Future<void> closeOrbitsDatabase() async {
  final db = _singleton;
  _singleton = null;
  await db?.close();
}
