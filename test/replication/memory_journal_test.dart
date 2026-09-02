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
}
