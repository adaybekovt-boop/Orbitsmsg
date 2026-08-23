// End-to-end proof for audit L3: message/peer `data` blobs are encrypted at
// rest under the vault KEK, AND a pre-L3 plaintext row still decodes (lossless
// lazy migration — history is never bricked).

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;
import 'package:orbits_flutter/storage/row_codec.dart';

void main() {
  late OrbitsDatabase database;

  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(
      List<int>.generate(32, (i) => (i * 5 + 3) & 0xff),
    );
  });

  tearDown(() async {
    clearVaultKek();
    await closeOrbitsDatabase();
  });

  test('message round-trips and is encrypted on disk', () async {
    await db.saveMessage({
      'id': 'm1',
      'peerId': 'ORBIT-AAAAAA',
      'timestamp': 1000,
      'direction': 'in',
      'status': 'delivered',
      'payload': {'kind': 'text', 'text': 'секрет 🔒'},
    });

    // Read back through the API — content survives the encrypt/decrypt round.
    final msgs = await db.getMessages('ORBIT-AAAAAA');
    expect(msgs, hasLength(1));
    final payload = msgs.first['payload'] as Map;
    expect(payload['text'], 'секрет 🔒');

    // The raw stored blob must actually be ciphertext, not plaintext JSON.
    final raw = await database.select(database.messagesTable).getSingle();
    expect(isBlobWrapped(raw.data), isTrue,
        reason: 'message data blob should be encrypted at rest');
  });

  test('peer round-trips and is encrypted on disk', () async {
    await db.savePeer({'id': 'ORBIT-BBBBBB', 'displayName': 'Алиса'});
    final peer = await db.getPeer('ORBIT-BBBBBB');
    expect(peer?['displayName'], 'Алиса');

    final raw = await database.select(database.peersTable).getSingle();
    expect(isBlobWrapped(raw.data), isTrue);
  });

  test('a legacy plaintext message row still decodes (migration)', () async {
    // Simulate a pre-L3 row: raw JSON bytes written straight to the column.
    final legacy = encodeRow(<String, Object?>{
      'id': 'old1',
      'peerId': 'ORBIT-CCCCCC',
      'timestamp': 500,
      'direction': 'out',
      'status': 'sent',
      'payload': {'kind': 'text', 'text': 'старое сообщение'},
    });
    expect(isBlobWrapped(legacy), isFalse); // truly plaintext

    await database.into(database.messagesTable).insert(
          MessagesTableCompanion.insert(
            id: 'old1',
            peerId: 'ORBIT-CCCCCC',
            timestamp: 500,
            direction: 'out',
            status: 'sent',
            data: legacy,
          ),
        );

    final got = await db.getMessageById('old1');
    expect(got, isNotNull);
    expect((got!['payload'] as Map)['text'], 'старое сообщение');
  });

  test('locked vault refuses a message write (S-1 / S-2)', () async {
    clearVaultKek();
    expect(
      () => db.saveMessage({
        'id': 'locked1',
        'peerId': 'ORBIT-LOCK01',
        'timestamp': 1,
        'direction': 'out',
        'status': 'sent',
        'payload': {'kind': 'text', 'text': 'must-not-hit-disk'},
      }),
      throwsStateError,
    );
    final rows = await database.select(database.messagesTable).get();
    expect(rows, isEmpty);
  });

  test('raw DB dump does not contain the message plaintext', () async {
    const secret = 'уникальный-секрет-XYZ-9f3a';
    await db.saveMessage({
      'id': 'm-dump',
      'peerId': 'ORBIT-DUMP01',
      'timestamp': 2,
      'direction': 'in',
      'status': 'delivered',
      'payload': {'kind': 'text', 'text': secret},
    });
    final raw = await database.select(database.messagesTable).getSingle();
    final asText = utf8.decode(raw.data, allowMalformed: true);
    expect(asText, isNot(contains(secret)));
    expect(asText, isNot(contains('уникальный')));
  });

  test('voice blob is encrypted at rest and round-trips', () async {
    const marker = 'PCM-SECRET-VOICE-7c2e';
    final ok = await db.saveVoiceBlob('v1', utf8.encode(marker), mime: 'audio/webm');
    expect(ok, isTrue);

    final raw = await database.select(database.voiceBlobsTable).getSingle();
    expect(isBlobWrapped(raw.bytes), isTrue);
    expect(utf8.decode(raw.bytes, allowMalformed: true), isNot(contains(marker)));

    final got = await db.getVoiceBlob('v1');
    expect(utf8.decode(got!['blob'] as List<int>), marker);
  });

  test('file blob and thumb are encrypted at rest', () async {
    const marker = 'FILE-SECRET-BODY-aa11';
    const thumbMarker = 'THUMB-SECRET-bb22';
    final ok = await db.saveFileBlob(
      'f1',
      utf8.encode(marker),
      mime: 'application/octet-stream',
      name: 'note.txt',
      thumb: utf8.encode(thumbMarker),
    );
    expect(ok, isTrue);

    final raw = await database.select(database.fileBlobsTable).getSingle();
    expect(isBlobWrapped(raw.bytes), isTrue);
    expect(utf8.decode(raw.bytes, allowMalformed: true), isNot(contains(marker)));
    expect(isBlobWrapped(raw.thumb!), isTrue);
    expect(
      utf8.decode(raw.thumb!, allowMalformed: true),
      isNot(contains(thumbMarker)),
    );

    final got = await db.getFileBlob('f1');
    expect(utf8.decode(got!['blob'] as List<int>), marker);
    expect(utf8.decode(got['thumb'] as List<int>), thumbMarker);
  });

  test('avatar is encrypted at rest and a legacy plaintext avatar still reads',
      () async {
    const url =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1'
        'HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    expect(await db.saveAvatar('ORBIT-AVA001', url), isTrue);

    final raw = await database.select(database.avatarsTable).getSingle();
    expect(isBlobWrapped(raw.data), isTrue);
    expect(utf8.decode(raw.data, allowMalformed: true), isNot(contains('iVBORw0')));
    expect(await db.getAvatar('ORBIT-AVA001'), url);

    await database.delete(database.avatarsTable).go();
    await database.into(database.avatarsTable).insert(
          AvatarsTableCompanion.insert(
            peerId: 'ORBIT-AVA-OLD',
            data: Uint8List.fromList(utf8.encode(url)),
          ),
        );
    expect(await db.getAvatar('ORBIT-AVA-OLD'), url);
  });

  test('legacy plaintext voice blob still reads (lazy migration)', () async {
    await database.into(database.voiceBlobsTable).insert(
          VoiceBlobsTableCompanion.insert(
            id: 'legacy-voice',
            bytes: Uint8List.fromList(utf8.encode('old-pcm')),
            data: encodeRow(<String, Object?>{'waveform': <double>[]}),
          ),
        );
    final got = await db.getVoiceBlob('legacy-voice');
    expect(utf8.decode(got!['blob'] as List<int>), 'old-pcm');
  });
}
