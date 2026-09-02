import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/replication/hypercore_store.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

void main() {
  test('replication frames carry ciphertext only and converge', () {
    final a = HypercoreLocalStore('dev-a');
    final live = MemoryJournal('dev-a');
    final rec = live.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'e1',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[1, 2, 3],
      ),
    );
    a.append(rec);
    final frame = a.toReplicationFrame(rec);
    expect(frame['info'], kReplicationEventInfo);
    expect(jsonFieldsHavePlaintext(frame), isFalse);

    final b = HypercoreLocalStore('dev-b');
    expect(b.applyRemote(frame), isNotNull);
    expect(b.blocks, hasLength(1));
    expect(b.blocks.first.fields['encryptedEnvelope'], [1, 2, 3]);
    expect(b.blocks.first.fields.containsKey('plaintext'), isFalse);
  });

  test('applyRemote returns null when fields nest fileKey', () {
    final store = HypercoreLocalStore('dev-b');
    expect(
      store.applyRemote(<String, Object?>{
        'type': 'repl-event',
        'info': kReplicationEventInfo,
        'kind': ReplicationEventKind.messageEnvelopeCreated.name,
        'seq': 0,
        'writerDeviceId': 'dev-a',
        'fields': <String, Object?>{
          'eventId': 'e1',
          'encryptedEnvelope': <int>[1, 2, 3],
          'extra': <String, Object?>{'fileKey': 'x'},
        },
      }),
      isNull,
    );
    expect(store.blocks, isEmpty);
  });

  test('toReplicationFrame throws when fields nest fileKey', () {
    final store = HypercoreLocalStore('dev-a');
    // Bypass append: JournalRecord does not validate fields.
    const rec = JournalRecord(
      seq: 0,
      writerDeviceId: 'dev-a',
      kind: ReplicationEventKind.messageEnvelopeCreated,
      fields: <String, Object?>{
        'eventId': 'e1',
        'encryptedEnvelope': <int>[1, 2, 3],
        'extra': <String, Object?>{'fileKey': 'x'},
      },
    );
    expect(() => store.toReplicationFrame(rec), throwsArgumentError);
    expect(store.blocks, isEmpty);
  });

  test('applyRemote returns null when writerDeviceId contains ://', () {
    final store = HypercoreLocalStore('dev-b');
    expect(
      store.applyRemote(<String, Object?>{
        'type': 'repl-event',
        'info': kReplicationEventInfo,
        'kind': ReplicationEventKind.messageEnvelopeCreated.name,
        'seq': 0,
        'writerDeviceId': 'https://evil',
        'fields': <String, Object?>{
          'eventId': 'e1',
          'encryptedEnvelope': <int>[1, 2, 3],
        },
      }),
      isNull,
    );
    expect(store.blocks, isEmpty);
  });

  test('applyRemote returns null when kind contains ://', () {
    final store = HypercoreLocalStore('dev-b');
    expect(
      store.applyRemote(<String, Object?>{
        'type': 'repl-event',
        'info': kReplicationEventInfo,
        'kind': 'https://evil',
        'seq': 0,
        'writerDeviceId': 'dev-a',
        'fields': <String, Object?>{
          'eventId': 'e1',
          'encryptedEnvelope': <int>[1, 2, 3],
        },
      }),
      isNull,
    );
    expect(store.blocks, isEmpty);
  });

  test('toReplicationFrame throws when writerDeviceId contains ://', () {
    final store = HypercoreLocalStore('dev-a');
    const rec = JournalRecord(
      seq: 0,
      writerDeviceId: 'https://evil',
      kind: ReplicationEventKind.messageEnvelopeCreated,
      fields: <String, Object?>{
        'eventId': 'e1',
        'encryptedEnvelope': <int>[1, 2, 3],
      },
    );
    expect(() => store.toReplicationFrame(rec), throwsArgumentError);
    expect(store.blocks, isEmpty);
  });

  test('append throws when writerDeviceId contains ://', () {
    final store = HypercoreLocalStore('dev-a');
    const rec = JournalRecord(
      seq: 0,
      writerDeviceId: 'https://evil',
      kind: ReplicationEventKind.messageEnvelopeCreated,
      fields: <String, Object?>{
        'eventId': 'e1',
        'encryptedEnvelope': <int>[1, 2, 3],
      },
    );
    expect(() => store.append(rec), throwsArgumentError);
    expect(store.blocks, isEmpty);
  });

  test('applyRemote returns null when frame has top-level fileKey', () {
    final store = HypercoreLocalStore('dev-b');
    expect(
      store.applyRemote(<String, Object?>{
        'type': 'repl-event',
        'info': kReplicationEventInfo,
        'kind': ReplicationEventKind.messageEnvelopeCreated.name,
        'seq': 0,
        'writerDeviceId': 'dev-a',
        'fileKey': 'smuggle',
        'fields': <String, Object?>{
          'eventId': 'e1',
          'encryptedEnvelope': <int>[1, 2, 3],
        },
      }),
      isNull,
    );
    expect(store.blocks, isEmpty);
  });
}

bool jsonFieldsHavePlaintext(Map<String, Object?> frame) {
  final fields = frame['fields'];
  return fields is Map && fields.containsKey('plaintext');
}
