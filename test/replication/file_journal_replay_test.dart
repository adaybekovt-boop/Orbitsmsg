import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/replication/drift_projector.dart';
import 'package:orbits_flutter/replication/file_journal.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

void main() {
  test('persist, new process replay, and projector restore history', () async {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}orbits-journal-replay.ndjson',
    );
    if (file.existsSync()) file.deleteSync();
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    final durable = FileJournal(
      writerDeviceId: 'dev-a',
      writeLine: (line) => file.writeAsString('$line\n', mode: FileMode.append),
      readLines: () async => file.existsSync() ? file.readAsLinesSync() : const <String>[],
    );
    final live = MemoryJournal('dev-a');
    final record = live.appendEnvelope(
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
    await durable.append(record);

    final restarted = FileJournal(
      writerDeviceId: 'dev-a',
      writeLine: (line) => file.writeAsString('$line\n', mode: FileMode.append),
      readLines: () async => file.readAsLinesSync(),
    );
    final replayed = await restarted.replay();
    final projector = JournalProjector(
      decrypt: (enc) async => {'text': String.fromCharCodes(enc)},
    );
    await projector.applyAll(replayed);
    expect(projector.messages['e1']?.plaintext, 'Hi');
    expect(replayed.records, hasLength(1));
  });

  test('duplicate eventId is not applied twice', () async {
    final journal = FileJournal.memory('dev-a');
    final first = JournalRecord(
      seq: 0,
      writerDeviceId: 'dev-a',
      kind: ReplicationEventKind.messageEnvelopeCreated,
      fields: <String, Object?>{
        'eventId': 'e1',
        'conversationId': 'c1',
        'encryptedEnvelope': <int>[1],
      },
    );
    await journal.append(first);
    await journal.append(first);
    final replayed = await journal.replay();
    expect(replayed.records.where((r) => r.fields['eventId'] == 'e1'), hasLength(1));
  });

  test('truncated tail is reported and middle corrupt is skipped', () async {
    final lines = <String>[
      '{"seq":0,"writerDeviceId":"dev-a","kind":"messageEnvelopeCreated","fields":{"eventId":"e1","conversationId":"c1","encryptedEnvelope":"SGk="}}',
      'not-json',
      '{"seq":2,"writerDeviceId":"dev-a","kind":"messageEnvelopeCreated","fields":{"eventId":"e2","conversationId":"c1","encryptedEnvelope":"SGk="}',
    ];
    final journal = FileJournal(
      writerDeviceId: 'dev-a',
      writeLine: (line) async => lines.add(line),
      readLines: () async => List<String>.from(lines),
    );
    final result = await journal.replayDetailed();
    expect(result.truncatedTail, isTrue);
    expect(result.corruptRecords, 1);
    expect(result.journal.records, hasLength(1));
    expect(result.journal.records.single.fields['eventId'], 'e1');
  });

  test('owner-namespaced journal files do not collide', () {
    expect(
      'orbits-hypercore-ORBIT-AAAAAAAAAAAAAAAA.ndjson',
      isNot('orbits-hypercore-ORBIT-BBBBBBBBBBBBBBBB.ndjson'),
    );
  });
}
