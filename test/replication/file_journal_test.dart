import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/replication/drift_projector.dart';
import 'package:orbits_flutter/replication/file_journal.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

const _envelope = MessageEnvelopeCreated(
  eventId: 'e1',
  conversationId: 'c1',
  senderIdentity: 'alice',
  senderDeviceId: 'dev-a',
  logicalSequence: 1,
  createdAt: 1,
  encryptedEnvelope: <int>[72, 105],
);

void main() {
  test('file journal replay matches the live projection', () async {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}orbits-journal.ndjson',
    );
    if (file.existsSync()) file.deleteSync();
    final live = MemoryJournal('dev-a');
    final durable = FileJournal(
      writerDeviceId: 'dev-a',
      writeLine: (line) => file.writeAsString('$line\n', mode: FileMode.append),
      readLines: () async =>
          file.existsSync() ? file.readAsLinesSync() : const <String>[],
    );
    final event = live.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'e1',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[72, 105],
      ),
    );
    await durable.append(event);

    Future<Map<String, Object?>?> decrypt(List<int> enc, String conv) async => {
          'text': String.fromCharCodes(enc),
        };
    final fromLive = JournalProjector(decrypt: decrypt);
    await fromLive.applyAll(live);
    final fromDisk = JournalProjector(decrypt: decrypt);
    await fromDisk.applyAll(await durable.replay());
    expect(fromDisk.messages['e1']?.plaintext, fromLive.messages['e1']?.plaintext);
    expect(fromDisk.messages['e1']?.plaintext, 'Hi');
  });

  test('replay restores writer seq and device id, not a fresh append', () async {
    final durable = FileJournal.memory('dev-a');
    const membership = JournalRecord(
      seq: 7,
      writerDeviceId: 'dev-a',
      kind: ReplicationEventKind.roomMembershipChanged,
      fields: <String, Object?>{
        'roomId': 'room-1',
        'peerId': 'guest-1',
        'action': 'join',
        'eventId': 'mem-1',
      },
    );
    const envelope = JournalRecord(
      seq: 8,
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
    await durable.append(membership);
    await durable.append(envelope);

    final replayed = await durable.replay();
    expect(replayed.length, 2);
    expect(replayed.records[0].seq, 7);
    expect(replayed.records[0].writerDeviceId, 'dev-a');
    expect(replayed.records[0].kind, ReplicationEventKind.roomMembershipChanged);
    expect(replayed.records[0].fields['eventId'], 'mem-1');
    expect(replayed.records[0].fields['roomId'], 'room-1');
    expect(replayed.records[1].seq, 8);
    expect(replayed.records[1].writerDeviceId, 'dev-a');
    expect(replayed.records[1].fields['eventId'], 'e1');
    expect(replayed.records[1].fields['encryptedEnvelope'], const <int>[72, 105]);
    expect(
      replayed.records.every((r) => !r.fields.containsKey('fileKey')),
      isTrue,
    );
    expect(
      replayed.records.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );

    final adopted = MemoryJournal('other-device');
    expect(adopted.adopt(replayed.records[0]), isNotNull);
    expect(adopted.adopt(replayed.records[1]), isNotNull);
    expect(adopted.records[0].seq, 7);
    expect(adopted.records[0].writerDeviceId, 'dev-a');
    expect(adopted.records[1].seq, 8);
    expect(adopted.records[1].writerDeviceId, 'dev-a');
    expect(adopted.records[1].fields['eventId'], 'e1');
    expect(adopted.records[1].fields['encryptedEnvelope'], const <int>[72, 105]);

    final next = replayed.append(
      ReplicationEventKind.deviceRevoked,
      {'deviceId': 'gone'},
    );
    expect(next.seq, 9);
    expect(next.writerDeviceId, 'dev-a');
  });

  test('replay and append refuse fileKey and plaintext', () async {
    final durable = FileJournal.memory('dev-a');
    expect(
      () => durable.append(
        const JournalRecord(
          seq: 0,
          writerDeviceId: 'dev-a',
          kind: ReplicationEventKind.roomMembershipChanged,
          fields: <String, Object?>{
            'roomId': 'r1',
            'fileKey': 'nope',
          },
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => durable.append(
        JournalRecord(
          seq: 0,
          writerDeviceId: 'dev-a',
          kind: ReplicationEventKind.messageEnvelopeCreated,
          fields: <String, Object?>{
            ..._envelope.toJournalFields(),
            'plaintext': 'secret',
          },
        ),
      ),
      throwsArgumentError,
    );

    final lines = <String>[
      jsonEncode(<String, Object?>{
        'seq': 4,
        'writerDeviceId': 'dev-b',
        'kind': ReplicationEventKind.messageEnvelopeCreated.name,
        'fields': <String, Object?>{
          'eventId': 'e-leak',
          'encryptedEnvelope': base64Encode(const <int>[1, 2, 3]),
          'fileKey': 'nope',
          'plaintext': 'secret',
        },
      }),
    ];
    final tampered = FileJournal(
      writerDeviceId: 'dev-a',
      writeLine: (line) async => lines.add(line),
      readLines: () async => List<String>.from(lines),
    );
    final replayed = await tampered.replay();
    expect(replayed.length, 1);
    expect(replayed.records.single.seq, 4);
    expect(replayed.records.single.writerDeviceId, 'dev-b');
    expect(replayed.records.single.fields['eventId'], 'e-leak');
    expect(
      replayed.records.single.fields['encryptedEnvelope'],
      const <int>[1, 2, 3],
    );
    expect(replayed.records.single.fields.containsKey('fileKey'), isFalse);
    expect(replayed.records.single.fields.containsKey('plaintext'), isFalse);
  });

  test('replay drops a line whose fields nest discoverySecret', () async {
    final lines = <String>[
      jsonEncode(<String, Object?>{
        'seq': 1,
        'writerDeviceId': 'dev-b',
        'kind': ReplicationEventKind.messageEnvelopeCreated.name,
        'fields': <String, Object?>{
          'eventId': 'e-ok',
          'encryptedEnvelope': base64Encode(const <int>[1, 2, 3]),
        },
      }),
      jsonEncode(<String, Object?>{
        'seq': 2,
        'writerDeviceId': 'dev-b',
        'kind': ReplicationEventKind.messageEnvelopeCreated.name,
        'fields': <String, Object?>{
          'eventId': 'e-leak',
          'encryptedEnvelope': base64Encode(const <int>[4, 5, 6]),
          'extra': <String, Object?>{'discoverySecret': 'nope'},
        },
      }),
    ];
    final tampered = FileJournal(
      writerDeviceId: 'dev-a',
      writeLine: (line) async => lines.add(line),
      readLines: () async => List<String>.from(lines),
    );
    final replayed = await tampered.replay();
    expect(replayed.length, 1);
    expect(replayed.records.single.fields['eventId'], 'e-ok');
    expect(replayed.records.single.seq, 1);
    expect(
      replayed.records.any((r) => r.fields['eventId'] == 'e-leak'),
      isFalse,
    );
  });

  test('append refuses URL identifier values without writing', () async {
    final durable = FileJournal.memory('dev-a');
    expect(
      () => durable.append(
        const JournalRecord(
          seq: 0,
          writerDeviceId: 'dev-a',
          kind: ReplicationEventKind.messageEnvelopeCreated,
          fields: <String, Object?>{
            'eventId': 'https://evil',
            'conversationId': 'c1',
            'encryptedEnvelope': <int>[1],
          },
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => durable.append(
        const JournalRecord(
          seq: 0,
          writerDeviceId: 'dev-a',
          kind: ReplicationEventKind.deviceRevoked,
          fields: <String, Object?>{'deviceId': 'https://evil'},
        ),
      ),
      throwsArgumentError,
    );
    final replayed = await durable.replay();
    expect(replayed.length, 0);
  });

  test('replay skips URL conversationId and keeps a later honest line',
      () async {
    final lines = <String>[
      jsonEncode(<String, Object?>{
        'seq': 1,
        'writerDeviceId': 'dev-a',
        'kind': ReplicationEventKind.messageEnvelopeCreated.name,
        'fields': <String, Object?>{
          'eventId': 'e-leak',
          'conversationId': 'https://evil',
          'encryptedEnvelope': base64Encode(const <int>[1, 2, 3]),
        },
      }),
      jsonEncode(<String, Object?>{
        'seq': 2,
        'writerDeviceId': 'dev-a',
        'kind': ReplicationEventKind.messageEnvelopeCreated.name,
        'fields': <String, Object?>{
          'eventId': 'e-ok',
          'conversationId': 'c1',
          'encryptedEnvelope': base64Encode(const <int>[4, 5, 6]),
        },
      }),
    ];
    final journal = FileJournal(
      writerDeviceId: 'dev-a',
      writeLine: (line) async => lines.add(line),
      readLines: () async => List<String>.from(lines),
    );
    final replayed = await journal.replay();
    expect(replayed.length, 1);
    expect(replayed.records.single.seq, 2);
    expect(replayed.records.single.fields['eventId'], 'e-ok');
    expect(replayed.records.single.fields['conversationId'], 'c1');
    expect(
      replayed.records.any((r) => r.fields['eventId'] == 'e-leak'),
      isFalse,
    );
  });

  test('append refuses URL writerDeviceId without writing', () async {
    final durable = FileJournal.memory('dev-a');
    expect(
      () => durable.append(
        const JournalRecord(
          seq: 0,
          writerDeviceId: 'https://evil',
          kind: ReplicationEventKind.deviceRevoked,
          fields: <String, Object?>{'deviceId': 'gone'},
        ),
      ),
      throwsArgumentError,
    );
    final replayed = await durable.replay();
    expect(replayed.length, 0);
  });

  test('replay skips URL writer line and keeps a later legit line', () async {
    final lines = <String>[
      jsonEncode(<String, Object?>{
        'seq': 1,
        'writerDeviceId': 'https://evil',
        'kind': ReplicationEventKind.deviceRevoked.name,
        'fields': <String, Object?>{'deviceId': 'gone'},
      }),
      jsonEncode(<String, Object?>{
        'seq': 2,
        'writerDeviceId': 'dev-a',
        'kind': ReplicationEventKind.roomMembershipChanged.name,
        'fields': <String, Object?>{
          'roomId': 'room-1',
          'peerId': 'guest-1',
          'action': 'join',
          'eventId': 'mem-1',
        },
      }),
    ];
    final journal = FileJournal(
      writerDeviceId: 'dev-a',
      writeLine: (line) async => lines.add(line),
      readLines: () async => List<String>.from(lines),
    );
    final replayed = await journal.replay();
    expect(replayed.length, 1);
    expect(replayed.records.single.seq, 2);
    expect(replayed.records.single.writerDeviceId, 'dev-a');
    expect(replayed.records.single.kind, ReplicationEventKind.roomMembershipChanged);
    expect(replayed.records.single.fields['eventId'], 'mem-1');
    expect(
      replayed.records.any((r) => r.writerDeviceId.contains('://')),
      isFalse,
    );
  });
}
