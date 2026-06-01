// Port of src/core/stickerManager.js — local sticker-pack manager.
//
// The JS version keeps packs in IndexedDB (via db.js helpers:
// putStickerPack / getStickerPack / getAllStickerPacks / deleteStickerPack /
// pushRecentSticker / getRecentStickers). The default packs are generated
// on first run as inline SVG data URLs wrapping a big emoji.
//
// In Flutter the persistence target is Drift (the same DB that backs the
// rest of the app). Persistence is pluggable via [StickerStore]: the concrete
// Drift-backed implementation lives in `storage/drift_sticker_store.dart` and
// is wired at startup (`installDriftStickerStore()` in main.dart). The
// in-memory fallback below is kept for tests and for any early call before
// the store is installed.
//
// API shape mirrors the JS exports:
//   DEFAULT_PACKS / defaultPacks
//   ensureDefaultPacks()
//   getInstalledPacks()
//   installPack(pack)
//   uninstallPack(packId)
//   recordStickerUsage(packId, stickerId)
//   getRecents({limit})
//   resolveSticker(packId, stickerId)

import 'dart:convert';

class Sticker {
  const Sticker({
    required this.id,
    required this.emoji,
    required this.url,
    required this.label,
  });

  final String id;
  final String emoji;
  final String url;
  final String label;

  Map<String, Object?> toJson() => {
        'id': id,
        'emoji': emoji,
        'url': url,
        'label': label,
      };

  factory Sticker.fromJson(Map<String, Object?> raw) => Sticker(
        id: raw['id']?.toString() ?? '',
        emoji: raw['emoji']?.toString() ?? '',
        url: raw['url']?.toString() ?? '',
        label: raw['label']?.toString() ?? '',
      );
}

class StickerPack {
  const StickerPack({
    required this.id,
    required this.name,
    required this.author,
    required this.thumbnail,
    required this.stickers,
    this.installedAt = 0,
  });

  final String id;
  final String name;
  final String author;
  final String thumbnail;
  final List<Sticker> stickers;
  final int installedAt;

  StickerPack copyWith({int? installedAt}) => StickerPack(
        id: id,
        name: name,
        author: author,
        thumbnail: thumbnail,
        stickers: stickers,
        installedAt: installedAt ?? this.installedAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'author': author,
        'thumbnail': thumbnail,
        'stickers': stickers.map((s) => s.toJson()).toList(),
        'installedAt': installedAt,
      };

  factory StickerPack.fromJson(Map<String, Object?> raw) {
    final rawStickers = raw['stickers'];
    return StickerPack(
      id: raw['id']?.toString() ?? '',
      name: raw['name']?.toString() ?? '',
      author: raw['author']?.toString() ?? 'Orbits',
      thumbnail: raw['thumbnail']?.toString() ?? '',
      stickers: rawStickers is List
          ? rawStickers
              .whereType<Map>()
              .map((m) => Sticker.fromJson(m.map((k, v) => MapEntry(k.toString(), v))))
              .toList()
          : const [],
      installedAt: raw['installedAt'] is int ? raw['installedAt'] as int : 0,
    );
  }
}

String _svgDataUrl(String emoji) {
  const head = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">'
      '<text x="50%" y="54%" dominant-baseline="middle" text-anchor="middle" '
      'font-size="96" font-family="\'Apple Color Emoji\',\'Segoe UI Emoji\','
      '\'Noto Color Emoji\',sans-serif">';
  const tail = '</text></svg>';
  return 'data:image/svg+xml;utf8,${Uri.encodeComponent('$head$emoji$tail')}';
}

StickerPack _buildDefaultPack(String id, String name, List<String> emojis) {
  return StickerPack(
    id: id,
    name: name,
    author: 'Orbits',
    thumbnail: _svgDataUrl(emojis[0]),
    stickers: [
      for (var i = 0; i < emojis.length; i++)
        Sticker(
          id: '${id}_$i',
          emoji: emojis[i],
          url: _svgDataUrl(emojis[i]),
          label: emojis[i],
        ),
    ],
  );
}

/// Default packs — byte-for-byte equivalent to the JS `DEFAULT_PACKS`.
final List<StickerPack> defaultPacks = List.unmodifiable([
  _buildDefaultPack('orbits_faces', 'Лица', [
    '😀','😁','😂','🤣','😊','😇','🙂','😉','😍','🥰',
    '😘','😜','🤪','🤔','🤨','😐','😴','🥱','😭','😤',
    '😡','🤯','🥳','😎','🤩','🙃','🫡','🥹'
  ]),
  _buildDefaultPack('orbits_hearts', 'Сердца', [
    '❤️','🧡','💛','💚','💙','💜','🖤','🤍','🤎','💖',
    '💘','💝','💓','💞','💕','💌','💟','❣️','💔','♥️'
  ]),
  _buildDefaultPack('orbits_gestures', 'Жесты', [
    '👍','👎','👌','✌️','🤞','🤟','🤘','🤙','👈','👉',
    '👆','👇','✋','🤚','🖐️','👋','🤝','🙏','💪','🫶',
    '🫰','🫵','👏','🙌'
  ]),
  _buildDefaultPack('orbits_animals', 'Животные', [
    '🐶','🐱','🦊','🐻','🐼','🐨','🐯','🦁','🐮','🐷',
    '🐸','🐵','🐔','🐧','🐦','🐤','🦄','🐝','🦋','🐙',
    '🐳','🐬','🦈','🐊'
  ]),
  _buildDefaultPack('orbits_party', 'Вечеринка', [
    '🎉','🎊','🎈','🎂','🍰','🎁','🎀','🪅','🎆','🎇',
    '✨','⭐','🌟','💫','🔥','💥','🏆','🥇','🎯','🎮'
  ]),
]);

/// Recent-sticker entry as used on the wire — the JS db returns rows with a
/// `key` of shape `${packId}:${stickerId}`.
class RecentStickerRow {
  const RecentStickerRow({required this.key, required this.at});
  final String key;
  final int at;
}

/// Persistence layer — Drift-backed impl should satisfy this. The default
/// implementation is in-memory only so the feature works end-to-end before
/// the DB schema lands.
abstract class StickerStore {
  Future<void> putPack(StickerPack pack);
  Future<StickerPack?> getPack(String packId);
  Future<List<StickerPack>> getAllPacks();
  Future<void> deletePack(String packId);
  Future<void> pushRecent(String packId, String stickerId);
  Future<List<RecentStickerRow>> getRecents(int limit);
}

class _InMemoryStickerStore implements StickerStore {
  final Map<String, String> _packs = {}; // packId → JSON
  final List<RecentStickerRow> _recents = [];

  @override
  Future<void> putPack(StickerPack pack) async {
    _packs[pack.id] = jsonEncode(pack.toJson());
  }

  @override
  Future<StickerPack?> getPack(String packId) async {
    final raw = _packs[packId];
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return StickerPack.fromJson(decoded.map((k, v) => MapEntry(k.toString(), v)));
  }

  @override
  Future<List<StickerPack>> getAllPacks() async {
    return _packs.values
        .map((raw) => jsonDecode(raw))
        .whereType<Map>()
        .map((m) => StickerPack.fromJson(m.map((k, v) => MapEntry(k.toString(), v))))
        .toList();
  }

  @override
  Future<void> deletePack(String packId) async {
    _packs.remove(packId);
  }

  @override
  Future<void> pushRecent(String packId, String stickerId) async {
    final key = '$packId:$stickerId';
    _recents.removeWhere((r) => r.key == key);
    _recents.insert(0, RecentStickerRow(
      key: key,
      at: DateTime.now().millisecondsSinceEpoch,
    ));
    if (_recents.length > 64) _recents.removeRange(64, _recents.length);
  }

  @override
  Future<List<RecentStickerRow>> getRecents(int limit) async {
    final n = limit < _recents.length ? limit : _recents.length;
    return _recents.sublist(0, n);
  }
}

StickerStore _store = _InMemoryStickerStore();

/// Swap in a production-grade sticker store (Drift-backed). Call once from
/// app startup, after the DB has been opened.
void setStickerStore(StickerStore store) {
  _store = store;
}

bool _ensuredDefaults = false;

/// Install default packs on first run. Safe to call repeatedly.
Future<void> ensureDefaultPacks() async {
  if (_ensuredDefaults) return;
  _ensuredDefaults = true;
  try {
    final existing = await _store.getAllPacks();
    final existingMap = {for (final p in existing) p.id: p};
    for (final pack in defaultPacks) {
      final saved = existingMap[pack.id];
      final missingOrEmpty = saved == null || saved.stickers.isEmpty;
      if (missingOrEmpty) {
        await _store.putPack(
          pack.copyWith(installedAt: DateTime.now().millisecondsSinceEpoch),
        );
      }
    }
  } catch (_) {}
}

/// All installed packs, oldest-installed first. Falls back to [defaultPacks]
/// on any DB error so the sticker picker always has something to show.
Future<List<StickerPack>> getInstalledPacks() async {
  try {
    await ensureDefaultPacks();
    final rows = await _store.getAllPacks();
    rows.sort((a, b) => a.installedAt.compareTo(b.installedAt));
    return rows;
  } catch (_) {
    return defaultPacks;
  }
}

Future<bool> installPack(StickerPack? pack) async {
  if (pack == null || pack.id.isEmpty) return false;
  await _store.putPack(
    pack.copyWith(installedAt: DateTime.now().millisecondsSinceEpoch),
  );
  return true;
}

Future<bool> uninstallPack(String packId) async {
  await _store.deletePack(packId);
  return true;
}

Future<void> recordStickerUsage(String packId, String stickerId) async {
  try {
    await _store.pushRecent(packId, stickerId);
  } catch (_) {}
}

/// A recent sticker resolved against installed packs.
class ResolvedSticker {
  const ResolvedSticker({required this.pack, required this.sticker});
  final StickerPack pack;
  final Sticker sticker;
}

/// Top N recently-used stickers, newest first. Entries whose pack has since
/// been uninstalled are skipped.
Future<List<ResolvedSticker>> getRecents({int limit = 24}) async {
  try {
    final rows = await _store.getRecents(limit);
    final packs = await getInstalledPacks();
    final byKey = <String, ResolvedSticker>{};
    for (final p in packs) {
      for (final s in p.stickers) {
        byKey['${p.id}:${s.id}'] = ResolvedSticker(pack: p, sticker: s);
      }
    }
    final results = <ResolvedSticker>[];
    for (final r in rows) {
      final hit = byKey[r.key];
      if (hit != null) results.add(hit);
    }
    return results;
  } catch (_) {
    return const [];
  }
}

/// Look up a single sticker by its pack + sticker id. Returns null if either
/// is missing.
Future<ResolvedSticker?> resolveSticker(String packId, String stickerId) async {
  try {
    final pack = await _store.getPack(packId);
    if (pack == null) return null;
    Sticker? match;
    for (final s in pack.stickers) {
      if (s.id == stickerId) {
        match = s;
        break;
      }
    }
    if (match == null) return null;
    return ResolvedSticker(pack: pack, sticker: match);
  } catch (_) {
    return null;
  }
}
