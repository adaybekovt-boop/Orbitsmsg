import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/replication/drift_projector.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

void main() {
  test('live apply and replay produce the same projection', () async {
    final journal = MemoryJournal('dev-a');
    Future<Map<String, Object?>?> decrypt(List<int> enc) async => {
      'text': String.fromCharCodes(enc),
    };

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
      decrypt: (enc) async => {'text': String.fromCharCodes(enc)},
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
      decrypt: (enc) async => {'text': String.fromCharCodes(enc)},
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
      decrypt: (enc) async => {'text': String.fromCharCodes(enc)},
      revokedWriters: {'revoked-dev'},
    );
    await guarded.applyAll(other);
    expect(guarded.messages, isEmpty);

    final rolling = JournalProjector(
      decrypt: (enc) async {
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
}
