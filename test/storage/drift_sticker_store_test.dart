// DriftStickerStore — proves sticker packs + recents persist to the DB
// (replacing the in-memory fallback that lost everything on restart).

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/sticker_manager.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/drift_sticker_store.dart';

StickerPack _pack(String id, List<String> emojis) => StickerPack(
      id: id,
      name: 'Pack $id',
      author: 'Orbits',
      thumbnail: 'data:image/svg+xml;utf8,x',
      stickers: [
        for (var i = 0; i < emojis.length; i++)
          Sticker(
            id: '${id}_$i',
            emoji: emojis[i],
            url: 'data:image/svg+xml;utf8,$i',
            label: emojis[i],
          ),
      ],
      installedAt: 100 + id.hashCode % 1000,
    );

void main() {
  late OrbitsDatabase database;
  const store = DriftStickerStore();

  setUp(() {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
  });

  tearDown(() async {
    await closeOrbitsDatabase();
  });

  test('putPack / getPack round-trips a pack with its stickers', () async {
    await store.putPack(_pack('faces', ['😀', '😁', '😂']));
    final got = await store.getPack('faces');
    expect(got, isNotNull);
    expect(got!.id, 'faces');
    expect(got.name, 'Pack faces');
    expect(got.stickers, hasLength(3));
    expect(got.stickers.first.emoji, '😀');
    expect(got.stickers[2].url, endsWith('2'));
  });

  test('getAllPacks returns every persisted pack', () async {
    await store.putPack(_pack('a', ['😀']));
    await store.putPack(_pack('b', ['❤️']));
    final all = await store.getAllPacks();
    expect(all.map((p) => p.id).toSet(), {'a', 'b'});
  });

  test('deletePack removes it', () async {
    await store.putPack(_pack('gone', ['👍']));
    await store.deletePack('gone');
    expect(await store.getPack('gone'), isNull);
  });

  test('pushRecent records usage and dedupes by sticker', () async {
    await store.pushRecent('faces', 'faces_0');
    await store.pushRecent('faces', 'faces_1');
    await store.pushRecent('faces', 'faces_0'); // repeat → still one entry

    final recents = await store.getRecents(24);
    final keys = recents.map((r) => r.key).toList();
    expect(keys.toSet(), {'faces:faces_0', 'faces:faces_1'});
    expect(keys, hasLength(2));
  });

  test('getRecents respects the limit', () async {
    for (var i = 0; i < 5; i++) {
      await store.pushRecent('p', 's$i');
    }
    final recents = await store.getRecents(3);
    expect(recents, hasLength(3));
  });
}
