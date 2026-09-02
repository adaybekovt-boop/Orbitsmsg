import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

void main() {
  const envelope = MessageEnvelopeCreated(
    eventId: 'e1',
    conversationId: 'c1',
    senderIdentity: 'alice',
    senderDeviceId: 'dev-a',
    logicalSequence: 1,
    createdAt: 1,
    encryptedEnvelope: <int>[72, 105],
  );

  test('worklet round-trip keeps ciphertext and drops secrets', () {
    final live = MemoryJournal('dev-a')..appendEnvelope(envelope);
    live.append(ReplicationEventKind.deviceRevoked, {'deviceId': 'gone'});
    final rows = live.records.map(journalRecordToWorklet).toList();
    expect(jsonEncode(rows), isNot(contains('plaintext')));
    expect(jsonEncode(rows), isNot(contains('rootKey')));
    expect(
      rows.first['fields'],
      isA<Map>().having(
        (m) => m['encryptedEnvelope'],
        'encryptedEnvelope',
        base64Encode(const <int>[72, 105]),
      ),
    );

    final restored = MemoryJournal('dev-a');
    expect(ingestWorkletRows(restored, rows), 2);
    expect(restored.length, 2);
    final enc = restored.records.first.fields['encryptedEnvelope'];
    expect(enc, isA<List<int>>());
    expect(enc, const <int>[72, 105]);
    expect(
      restored.records.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(ingestWorkletRows(restored, rows), 0);
  });

  test('journalRecordFromWorklet refuses secrets and missing envelopes', () {
    expect(
      journalRecordFromWorklet({
        'kind': 'messageEnvelopeCreated',
        'writerDeviceId': 'dev-a',
        'fields': {
          'eventId': 'e1',
          'encryptedEnvelope': base64Encode(const <int>[1]),
          'rootKey': 'nope',
        },
      }),
      isNull,
    );
    expect(
      journalRecordFromWorklet({
        'kind': 'messageEnvelopeCreated',
        'writerDeviceId': 'dev-a',
        'fields': {'eventId': 'e1'},
      }),
      isNull,
    );
    expect(
      journalRecordFromWorklet({
        'kind': 'attachmentPublished',
        'writerDeviceId': 'dev-a',
        'fields': {'eventId': 'a1'},
      }),
      isNull,
    );
    final revoked = journalRecordFromWorklet({
      'kind': 'deviceRevoked',
      'writerDeviceId': 'dev-a',
      'seq': 3,
      'fields': {'deviceId': 'gone'},
    });
    expect(revoked, isNotNull);
    expect(revoked!.kind, ReplicationEventKind.deviceRevoked);
    expect(revoked.fields.containsKey('encryptedEnvelope'), isFalse);
  });

  test('ingestWorkletRows skips unknown kinds and bad base64 envelopes', () {
    final journal = MemoryJournal('dev-a');
    expect(
      ingestWorkletRows(journal, [
        {'kind': 'notAKind', 'fields': <String, Object?>{}},
        {
          'kind': 'messageEnvelopeCreated',
          'fields': {'encryptedEnvelope': '%%%not-base64%%%'},
        },
      ]),
      0,
    );
    expect(journal.length, 0);
  });

  test('adopt keeps durable seq and writer; ingest restamps', () {
    const rec = JournalRecord(
      seq: 7,
      writerDeviceId: 'dev-a',
      kind: ReplicationEventKind.messageEnvelopeCreated,
      fields: <String, Object?>{
        'eventId': 'e1',
        'conversationId': 'c1',
        'senderIdentity': 'alice',
        'senderDeviceId': 'dev-a',
        'logicalSequence': 1,
        'createdAt': 1,
        'encryptedEnvelope': <int>[72, 105],
      },
    );

    final ingested = MemoryJournal('other');
    expect(ingested.ingest(rec), isNotNull);
    expect(ingested.records.single.seq, 0);
    expect(ingested.records.single.writerDeviceId, 'other');
    expect(ingested.records.single.fields['eventId'], 'e1');
    expect(
      ingested.records.single.fields['encryptedEnvelope'],
      const <int>[72, 105],
    );

    final adopted = MemoryJournal('other');
    expect(adopted.adopt(rec), isNotNull);
    expect(adopted.records.single.seq, 7);
    expect(adopted.records.single.writerDeviceId, 'dev-a');
    expect(adopted.records.single.fields['eventId'], 'e1');
    expect(
      adopted.records.single.fields['encryptedEnvelope'],
      const <int>[72, 105],
    );
    expect(adopted.records.single.fields.containsKey('fileKey'), isFalse);
    expect(adopted.records.single.fields.containsKey('plaintext'), isFalse);

    final next = adopted.append(
      ReplicationEventKind.deviceRevoked,
      {'deviceId': 'gone'},
    );
    expect(next.seq, 8);
    expect(next.writerDeviceId, 'other');
  });

  test('adopt reuses ingest duplicate skips without restamping', () {
    final journal = MemoryJournal('local');
    const first = JournalRecord(
      seq: 3,
      writerDeviceId: 'dev-a',
      kind: ReplicationEventKind.messageEnvelopeCreated,
      fields: <String, Object?>{
        'eventId': 'e1',
        'encryptedEnvelope': <int>[72, 105],
      },
    );
    expect(journal.adopt(first), isNotNull);
    expect(
      journal.adopt(
        const JournalRecord(
          seq: 9,
          writerDeviceId: 'dev-b',
          kind: ReplicationEventKind.messageEnvelopeCreated,
          fields: <String, Object?>{
            'eventId': 'e1',
            'encryptedEnvelope': <int>[9],
          },
        ),
      ),
      isNull,
    );
    expect(
      journal.adopt(
        const JournalRecord(
          seq: 10,
          writerDeviceId: 'dev-c',
          kind: ReplicationEventKind.messageEnvelopeCreated,
          fields: <String, Object?>{
            'eventId': 'e2',
            'encryptedEnvelope': <int>[72, 105],
          },
        ),
      ),
      isNull,
    );
    const revoke = JournalRecord(
      seq: 4,
      writerDeviceId: 'dev-a',
      kind: ReplicationEventKind.deviceRevoked,
      fields: <String, Object?>{'deviceId': 'gone'},
    );
    expect(journal.adopt(revoke), isNotNull);
    expect(
      journal.adopt(
        const JournalRecord(
          seq: 11,
          writerDeviceId: 'other',
          kind: ReplicationEventKind.deviceRevoked,
          fields: <String, Object?>{'deviceId': 'gone'},
        ),
      ),
      isNull,
    );
    expect(journal.length, 2);
    expect(journal.records[0].seq, 3);
    expect(journal.records[0].writerDeviceId, 'dev-a');
    expect(journal.records[1].seq, 4);
    expect(journal.records[1].writerDeviceId, 'dev-a');
    expect(journal.append(ReplicationEventKind.contactBlocked, {
      'peerId': 'eve',
    }).seq, 5);
  });

  test('append and fromWorklet refuse nested fileKey and rootKey', () {
    final journal = MemoryJournal('dev-a');
    expect(
      () => journal.append(
        ReplicationEventKind.attachmentPublished,
        {
          'eventId': 'att-1',
          'encryptedEnvelope': <int>[1],
          'extra': {'fileKey': 'x'},
        },
      ),
      throwsArgumentError,
    );
    expect(journal.length, 0);
    expect(
      () => journal.append(
        ReplicationEventKind.messageEnvelopeCreated,
        {
          'eventId': 'e1',
          'encryptedEnvelope': <int>[1],
          'meta': {'rootKey': 'nope'},
        },
      ),
      throwsArgumentError,
    );
    expect(journal.length, 0);
    expect(
      journalRecordFromWorklet({
        'kind': 'messageEnvelopeCreated',
        'writerDeviceId': 'dev-a',
        'fields': {
          'eventId': 'e1',
          'encryptedEnvelope': base64Encode(const <int>[1]),
          'extra': {'fileKey': 'x'},
        },
      }),
      isNull,
    );
    expect(
      journalRecordFromWorklet({
        'kind': 'deviceRevoked',
        'writerDeviceId': 'dev-a',
        'fields': {
          'deviceId': 'gone',
          'meta': {'rootKey': 'nope'},
        },
      }),
      isNull,
    );
    expect(journal.length, 0);
  });

  test('adopt refuses fileKey and plaintext', () {
    final journal = MemoryJournal('dev-a');
    expect(
      () => journal.adopt(
        const JournalRecord(
          seq: 1,
          writerDeviceId: 'dev-a',
          kind: ReplicationEventKind.attachmentPublished,
          fields: <String, Object?>{
            'eventId': 'att-1',
            'encryptedEnvelope': <int>[1],
            'fileKey': 'nope',
          },
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => journal.adopt(
        const JournalRecord(
          seq: 2,
          writerDeviceId: 'dev-b',
          kind: ReplicationEventKind.messageEnvelopeCreated,
          fields: <String, Object?>{
            'eventId': 'e1',
            'encryptedEnvelope': <int>[1],
            'plaintext': 'secret',
          },
        ),
      ),
      throwsArgumentError,
    );
    expect(journal.length, 0);
  });
}
