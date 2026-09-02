// Slice 4 — Drift saveMessage / updateMessage must refuse ratchet /
// identity / discovery secrets in `payload`, while still allowing outbox
// `fileKeyB64` (retry must not mint a second XOR key).

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;

void main() {
  late OrbitsDatabase database;

  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 11 + 2) & 0xff));
  });

  tearDown(() async {
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  test('messagePayloadIsSafeToPersist allows outbox keys and room text', () {
    expect(
      db.messagePayloadIsSafeToPersist({
        'type': 'file',
        'attachment': {'name': 'a', 'fileKeyB64': 'xx', 'fileKey': 'yy'},
      }),
      isTrue,
    );
    expect(
      db.messagePayloadIsSafeToPersist({
        'type': 'text',
        'text': 'hi',
        'b64': 'YQ==',
        'peerId': 'ORBIT-PEER',
      }),
      isTrue,
    );
    expect(
      db.messagePayloadIsSafeToPersist({
        'type': 'text',
        'text': 'hi',
        'extra': {'kek': 'x'},
      }),
      isFalse,
    );
  });

  test('messagePayloadIsSafeToPersist is cycle-safe', () {
    final cyclic = <String, Object?>{'type': 'text', 'text': 'hi'};
    cyclic['self'] = cyclic;
    expect(db.messagePayloadIsSafeToPersist(cyclic), isTrue);

    final cyclicSecret = <String, Object?>{'rootKey': 'y'};
    cyclicSecret['self'] = cyclicSecret;
    expect(db.messagePayloadIsSafeToPersist(cyclicSecret), isFalse);
  });

  test('saveMessage refuses nested kek and does not persist', () async {
    final ok = await db.saveMessage({
      'id': 'm-kek',
      'peerId': 'ORBIT-SECRETS01',
      'timestamp': 1000,
      'direction': 'out',
      'status': 'pending',
      'payload': {
        'type': 'text',
        'text': 'hi',
        'extra': {'kek': 'x'},
      },
    });
    expect(ok, isFalse);
    expect(await db.getMessageById('m-kek'), isNull);
    expect(await database.select(database.messagesTable).get(), isEmpty);
  });

  test('saveMessage allows outbox attachment fileKeyB64', () async {
    final ok = await db.saveMessage({
      'id': 'm-file',
      'peerId': 'ORBIT-SECRETS02',
      'timestamp': 1001,
      'direction': 'out',
      'status': 'pending',
      'payload': {
        'type': 'file',
        'attachment': {'name': 'a', 'fileKeyB64': 'xx'},
      },
    });
    expect(ok, isTrue);
    final got = await db.getMessageById('m-file');
    expect(got, isNotNull);
    final att = (got!['payload'] as Map)['attachment'] as Map;
    expect(att['fileKeyB64'], 'xx');
  });

  test('saveMessage allows legit text payload', () async {
    final ok = await db.saveMessage({
      'id': 'm-text',
      'peerId': 'ORBIT-SECRETS03',
      'timestamp': 1002,
      'direction': 'out',
      'status': 'sent',
      'payload': {'type': 'text', 'text': 'hi'},
    });
    expect(ok, isTrue);
    final got = await db.getMessageById('m-text');
    expect(got, isNotNull);
    expect((got!['payload'] as Map)['text'], 'hi');
  });

  test('updateMessage does not persist rootKey from payload patch', () async {
    expect(
      await db.saveMessage({
        'id': 'm-upd',
        'peerId': 'ORBIT-SECRETS04',
        'timestamp': 1003,
        'direction': 'out',
        'status': 'sent',
        'payload': {'type': 'text', 'text': 'hi'},
      }),
      isTrue,
    );

    final patched = await db.updateMessage('m-upd', {
      'payload': {'text': 'x', 'rootKey': 'y'},
    });
    expect(patched, isFalse);

    final got = await db.getMessageById('m-upd');
    expect(got, isNotNull);
    final payload = got!['payload'] as Map;
    expect(payload.containsKey('rootKey'), isFalse);
    expect(payload['text'], 'hi');
  });
}
