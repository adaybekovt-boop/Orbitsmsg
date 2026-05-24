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
  @override
  int get schemaVersion => 2;

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

          // Peer list: contact picker sorts by lastSeenAt DESC, and
          // "trusted" filters to verified peers first.
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_peers_last_seen '
            'ON peers(last_seen_at)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_peers_trusted '
            'ON peers(trusted)',
          );

          // Chat paging: `WHERE peerId=? ORDER BY timestamp DESC`.
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_messages_peer_ts '
            'ON messages(peer_id, timestamp)',
          );

          // Pending queue per peer: `WHERE peerId=? AND status='pending'`.
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
        },
        beforeOpen: (details) async {
          // Foreign-key enforcement defaults to OFF in SQLite; turn on
          // so future `REFERENCES` columns behave as declared.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}

/// Pick up the bundled sqlite3 via `sqlite3_flutter_libs` and open
/// `<appSupportDir>/orbits.sqlite`. Runs I/O on a shared background
/// isolate so bulk inserts don't jank the UI.
QueryExecutor _open() => driftDatabase(
      name: 'orbits',
      native: const DriftNativeOptions(
        shareAcrossIsolates: true,
      ),
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
      ),
    );

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
