import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/replication/drift_projector.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

void main() {
  test('live apply and replay produce the same projection', () async {
    final journal = MemoryJournal('dev-a');
    Future<Map<String, Object?>?> decrypt(
      List<int> enc,
      JournalRecord _,
    ) async => {'text': String.fromCharCodes(enc)};

    const first = MessageEnvelopeCreated(
      eventId: 'e1',
      conversationId: 'c1',
      senderIdentity: 'alice',
      senderDeviceId: 'dev-a',
      logicalSequence: 1,
      createdAt: 1,
      encryptedEnvelope: <int>[72, 105],
    );
    journal.appendEnvelope(first);
    journal.append(ReplicationEventKind.deliveryAcknowledged, {
      'eventId': 'e1',
    });

    final live = JournalProjector(decrypt: decrypt);
    await live.applyAll(journal);

    final replay = JournalProjector(decrypt: decrypt);
    await replay.applyAll(journal);

    expect(replay.messages.keys, live.messages.keys);
    expect(replay.messages['e1']?.plaintext, 'Hi');
    expect(replay.messages['e1']?.status, live.messages['e1']?.status);
    expect(replay.cursor, live.cursor);
  });

  test('duplicates and missing seq do not corrupt the projection', () async {
    final journal = MemoryJournal('dev-a');
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'e1',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[65],
      ),
    );
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'e1',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[65],
      ),
    );
    final projector = JournalProjector(
      decrypt: (enc, _) async => {'text': String.fromCharCodes(enc)},
    );
    await projector.applyAll(journal);
    expect(projector.messages, hasLength(1));
  });

  test('journal rejects secret fields', () {
    final journal = MemoryJournal('dev-a');
    expect(
      () => journal.append(ReplicationEventKind.deviceAuthorized, {
        'rootKey': 'nope',
      }),
      throwsArgumentError,
    );
  });

  test('unknown version, revoked writer, and transaction rollback', () async {
    final journal = MemoryJournal('dev-a');
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'ok',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[65],
        eventVersion: 1,
      ),
    );
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'future',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 2,
        createdAt: 2,
        encryptedEnvelope: <int>[66],
        eventVersion: 99,
      ),
    );
    final projector = JournalProjector(
      decrypt: (enc, _) async => {'text': String.fromCharCodes(enc)},
      revokedWriters: {'revoked-dev'},
    );
    await projector.applyAll(journal);
    expect(projector.messages.keys, ['ok']);

    final other = MemoryJournal('revoked-dev');
    other.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'nope',
        conversationId: 'c1',
        senderIdentity: 'eve',
        senderDeviceId: 'revoked-dev',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[67],
      ),
    );
    final guarded = JournalProjector(
      decrypt: (enc, _) async => {'text': String.fromCharCodes(enc)},
      revokedWriters: {'revoked-dev'},
    );
    await guarded.applyAll(other);
    expect(guarded.messages, isEmpty);

    final rolling = JournalProjector(
      decrypt: (enc, _) async {
        if (enc.length == 1 && enc.first == 0) throw StateError('boom');
        return {'text': 'x'};
      },
    );
    await expectLater(
      rolling.applyInTransaction([
        JournalRecord(
          seq: 0,
          writerDeviceId: 'dev-a',
          kind: ReplicationEventKind.messageEnvelopeCreated,
          fields: {
            'eventId': 't1',
            'conversationId': 'c',
            'senderIdentity': 'a',
            'senderDeviceId': 'dev-a',
            'encryptedEnvelope': <int>[1],
          },
        ),
        JournalRecord(
          seq: 1,
          writerDeviceId: 'dev-a',
          kind: ReplicationEventKind.messageEnvelopeCreated,
          fields: {
            'eventId': 't2',
            'conversationId': 'c',
            'senderIdentity': 'a',
            'senderDeviceId': 'dev-a',
            'encryptedEnvelope': <int>[0],
          },
        ),
      ]),
      throwsStateError,
    );
    expect(rolling.messages, isEmpty);
  });

  test('blocked sender is dropped before decrypt', () async {
    var decrypted = 0;
    final journal = MemoryJournal('dev-a');
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'blocked',
        conversationId: 'c1',
        senderIdentity: 'eve',
        senderDeviceId: 'dev-eve',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[69],
      ),
    );
    final projector = JournalProjector(
      decrypt: (enc, _) async {
        decrypted += 1;
        return {'text': String.fromCharCodes(enc)};
      },
      isBlocked: (peerId) => peerId == 'eve',
    );
    await projector.applyAll(journal);
    expect(decrypted, 0);
    expect(projector.messages, isEmpty);
    expect(projector.seenEventIds, isEmpty);
  });

  test('failed decrypt does not burn the event id', () async {
    var attempts = 0;
    final journal = MemoryJournal('dev-a');
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'late',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[70],
      ),
    );
    final projector = JournalProjector(
      decrypt: (enc, _) async {
        attempts += 1;
        if (attempts == 1) return null;
        return {'text': String.fromCharCodes(enc)};
      },
    );
    await projector.applyAll(journal);
    expect(projector.messages, isEmpty);
    expect(projector.seenEventIds, isEmpty);
    projector.cursor = 0;
    await projector.applyAll(journal);
    expect(projector.messages['late']?.plaintext, 'F');
    expect(projector.seenEventIds, contains('late'));
  });

  test('tombstone only applies for the original writer device', () async {
    final journal = MemoryJournal('dev-a');
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'keep',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[65],
      ),
    );
    final projector = JournalProjector(
      decrypt: (enc, _) async => {'text': String.fromCharCodes(enc)},
    );
    await projector.applyAll(journal);
    expect(projector.messages.containsKey('keep'), isTrue);

    await projector.apply(
      JournalRecord(
        seq: 99,
        writerDeviceId: 'eve-dev',
        kind: ReplicationEventKind.messageTombstoned,
        fields: {'eventId': 'keep'},
      ),
    );
    expect(projector.messages.containsKey('keep'), isTrue);

    await projector.apply(
      JournalRecord(
        seq: 100,
        writerDeviceId: 'dev-a',
        kind: ReplicationEventKind.messageTombstoned,
        fields: {'eventId': 'keep'},
      ),
    );
    expect(projector.messages.containsKey('keep'), isFalse);
  });

  test('successful decrypt persists inbound rows and skips own outbound',
      () async {
    final saved = <Map<String, Object?>>[];
    final tombstoned = <String>[];
    final projector = JournalProjector(
      decrypt: (enc, _) async => {'text': String.fromCharCodes(enc)},
      persist: (msg) => persistProjectedMessage(
        msg,
        selfPeerId: 'alice',
        save: (row) async {
          saved.add(row);
          return true;
        },
      ),
      tombstone: (id) async => tombstoned.add(id),
    );
    await projector.apply(
      JournalRecord(
        seq: 0,
        writerDeviceId: 'bob-dev',
        kind: ReplicationEventKind.messageEnvelopeCreated,
        fields: {
          'eventId': 'in-1',
          'conversationId': 'c1',
          'senderIdentity': 'bob',
          'senderDeviceId': 'bob-dev',
          'encryptedEnvelope': <int>[72, 105],
          'createdAt': 42,
        },
      ),
    );
    await projector.apply(
      JournalRecord(
        seq: 1,
        writerDeviceId: 'alice-dev',
        kind: ReplicationEventKind.messageEnvelopeCreated,
        fields: {
          'eventId': 'out-1',
          'conversationId': 'c1',
          'senderIdentity': 'alice',
          'senderDeviceId': 'alice-dev',
          'encryptedEnvelope': <int>[79],
          'createdAt': 43,
        },
      ),
    );
    expect(saved, hasLength(1));
    expect(saved.single['id'], 'in-1');
    expect(saved.single['peerId'], 'bob');
    expect(saved.single['direction'], 'in');
    expect((saved.single['payload'] as Map)['text'], 'Hi');
    expect(projector.messages['out-1']?.plaintext, 'O');

    await projector.apply(
      JournalRecord(
        seq: 2,
        writerDeviceId: 'bob-dev',
        kind: ReplicationEventKind.messageTombstoned,
        fields: {'eventId': 'in-1'},
      ),
    );
    expect(tombstoned, ['in-1']);
  });
}
