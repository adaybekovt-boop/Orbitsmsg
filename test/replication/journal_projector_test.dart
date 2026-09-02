import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/replication/drift_projector.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

void main() {
  test('live apply and replay produce the same projection', () async {
    final journal = MemoryJournal('dev-a');
    Future<Map<String, Object?>?> decrypt(List<int> enc, String conv) async => {
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
    expect(live.matches(replay), isTrue);
    replay.messages['e1'] = replay.messages['e1']!.copyWith(status: 'read');
    expect(live.matches(replay), isFalse);
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
      decrypt: (enc, conv) async => {'text': String.fromCharCodes(enc)},
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
    expect(
      () => journal.append(ReplicationEventKind.attachmentPublished, {
        'fileKey': 'nope',
        'encryptedEnvelope': <int>[1],
      }),
      throwsArgumentError,
    );
  });

  test('block list skips decrypt and persist', () async {
    final journal = MemoryJournal('dev-a');
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'e-blocked',
        conversationId: 'blocked-peer',
        senderIdentity: 'eve',
        senderDeviceId: 'dev-e',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[72, 105],
      ),
    );
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'e-ok',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 2,
        createdAt: 2,
        encryptedEnvelope: <int>[72, 105],
      ),
    );
    final decrypted = <String>[];
    final persisted = <String>[];
    final n = await projectJournalToReadModel(
      journal: journal,
      isBlocked: (id) => id == 'blocked-peer',
      decrypt: (enc, conv) async {
        decrypted.add(conv);
        return {'text': String.fromCharCodes(enc)};
      },
      persist: (msg) async => persisted.add(msg.eventId),
    );
    expect(n, 1);
    expect(decrypted, ['c1']);
    expect(persisted, ['e-ok']);
  });
}
