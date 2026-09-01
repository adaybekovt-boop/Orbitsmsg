import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/replication/drift_projector.dart';
import 'package:orbits_flutter/replication/file_journal.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

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
}
