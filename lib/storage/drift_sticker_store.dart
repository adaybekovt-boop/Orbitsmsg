// Drift-backed [StickerStore] — persists sticker packs and the recent-sticker
// list to the on-disk database, replacing the in-memory fallback in
// `core/sticker_manager.dart` (which lost everything on restart).
//
// The DB helpers already exist in `storage/db.dart` (putStickerPack /
// getAllStickerPacks / pushRecentSticker / …); this just adapts the
// StickerPack <-> Map shapes the manager and the DB speak. Wire it once at
// startup via [installDriftStickerStore] (see main.dart), after the Drift
// database is available.

import '../core/sticker_manager.dart';
import 'db.dart' as db;

class DriftStickerStore implements StickerStore {
  const DriftStickerStore();

  @override
  Future<void> putPack(StickerPack pack) async {
    await db.putStickerPack(pack.toJson());
  }

  @override
  Future<StickerPack?> getPack(String packId) async {
    final raw = await db.getStickerPack(packId);
    if (raw == null) return null;
    return StickerPack.fromJson(raw);
  }

  @override
  Future<List<StickerPack>> getAllPacks() async {
    final rows = await db.getAllStickerPacks();
    return rows.map(StickerPack.fromJson).toList();
  }

  @override
  Future<void> deletePack(String packId) async {
    await db.deleteStickerPack(packId);
  }

  @override
  Future<void> pushRecent(String packId, String stickerId) async {
    await db.pushRecentSticker(packId, stickerId);
  }

  @override
  Future<List<RecentStickerRow>> getRecents(int limit) async {
    final rows = await db.getRecentStickers(limit: limit);
    return rows
        .map((r) => RecentStickerRow(
              key: (r['key'] as String?) ?? '',
              at: (r['usedAt'] as num?)?.toInt() ?? 0,
            ))
        .toList();
  }
}

/// Install the Drift-backed sticker store process-wide. Call once at startup
/// after the database is ready.
void installDriftStickerStore() => setStickerStore(const DriftStickerStore());
