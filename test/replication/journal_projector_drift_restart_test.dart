import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/replication/drift_projector.dart';
import 'package:orbits_flutter/replication/file_journal.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;
import 'package:orbits_flutter/transport/replication_schema.dart';

void main() {
  late OrbitsDatabase database;

  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 3 + 7) & 0xff));
  });

  tearDown(() async {
    clearVaultKek();
    await closeOrbitsDatabase();
  });

  test('live Drift persist and journal replay match after restart', () async {
    final journal = MemoryJournal('dev-self');
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'in-1',
        conversationId: 'c1',
        senderIdentity: 'bob',
        senderDeviceId: 'dev-bob',
        logicalSequence: 1,
        createdAt: 100,
        encryptedEnvelope: <int>[72, 105],
      ),
    );
    journal.append(ReplicationEventKind.deliveryAcknowledged, {
      'eventId': 'in-1',
    });
    journal.append(ReplicationEventKind.roomMembershipChanged, {
      'eventId': 'host:0:room-1',
      'conversationId': 'c1',
      'senderIdentity': 'alice',
      'senderDeviceId': 'dev-self',
      'createdAt': 101,
      'roomId': 'room-1',
      'action': 'join',
      'memberPeerId': 'bob',
      'abWriter': 'host',
      'abSeq': 0,
    });

    Future<Map<String, Object?>?> decrypt(
      List<int> enc,
      JournalRecord _,
    ) async =>
        {'text': String.fromCharCodes(enc)};

    final live = JournalProjector(
      decrypt: decrypt,
      persist: (msg) => persistProjectedMessage(
        msg,
        selfPeerId: 'alice',
        save: db.saveMessage,
      ),
      tombstone: db.deleteMessageRow,
    );
    await live.applyAll(journal);

    final liveRows = await db.getMessages('bob');
    expect(liveRows, hasLength(1));
    expect((liveRows.single['payload'] as Map)['text'], 'Hi');
    expect(liveRows.single['status'], 'delivered');
    expect(live.membershipChanges.single['memberPeerId'], 'bob');

    await db.clearAllMessages();
    final replay = JournalProjector(
      decrypt: decrypt,
      persist: (msg) => persistProjectedMessage(
        msg,
        selfPeerId: 'alice',
        save: db.saveMessage,
      ),
      tombstone: db.deleteMessageRow,
    );
    await replay.applyAll(journal);
    final replayRows = await db.getMessages('bob');

    expect(replay.messages.keys, live.messages.keys);
    expect(replay.messages['in-1']?.plaintext, live.messages['in-1']?.plaintext);
    expect(replay.messages['in-1']?.status, live.messages['in-1']?.status);
    expect(replay.cursor, live.cursor);
    expect(replay.membershipChanges, live.membershipChanges);
    expect(replayRows, hasLength(1));
    expect(replayRows.single['id'], liveRows.single['id']);
    expect(
      (replayRows.single['payload'] as Map)['text'],
      (liveRows.single['payload'] as Map)['text'],
    );
    expect(replayRows.single['status'], liveRows.single['status']);
  });

  test('FileJournal restart replay writes the same Drift rows as live',
      () async {
    final durable = FileJournal.memory('dev-self');
    final liveJournal = MemoryJournal('dev-self');
    final record = liveJournal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'fj-1',
        conversationId: 'c1',
        senderIdentity: 'bob',
        senderDeviceId: 'dev-bob',
        logicalSequence: 1,
        createdAt: 200,
        encryptedEnvelope: <int>[79, 107],
      ),
    );
    await durable.append(record);

    Future<Map<String, Object?>?> decrypt(
      List<int> enc,
      JournalRecord _,
    ) async =>
        {'text': String.fromCharCodes(enc)};

    final live = JournalProjector(
      decrypt: decrypt,
      persist: (msg) => persistProjectedMessage(
        msg,
        selfPeerId: 'alice',
        save: db.saveMessage,
      ),
    );
    await live.applyAll(liveJournal);
    final liveRows = await db.getMessages('bob');
    expect((liveRows.single['payload'] as Map)['text'], 'Ok');

    await db.clearAllMessages();
    final replayed = await durable.replay();
    final replay = JournalProjector(
      decrypt: decrypt,
      persist: (msg) => persistProjectedMessage(
        msg,
        selfPeerId: 'alice',
        save: db.saveMessage,
      ),
    );
    await replay.applyAll(replayed);
    final replayRows = await db.getMessages('bob');
    expect(replay.messages['fj-1']?.plaintext, live.messages['fj-1']?.plaintext);
    expect(replayRows.single['id'], liveRows.single['id']);
    expect(
      (replayRows.single['payload'] as Map)['text'],
      (liveRows.single['payload'] as Map)['text'],
    );
  });
}
