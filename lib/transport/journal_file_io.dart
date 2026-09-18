import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../replication/file_journal.dart';

Future<FileJournal?> openLocalFileJournal(
  String deviceId, {
  String ownerPeerId = '',
  Directory? directory,
}) async {
  // Throws on IO failure so the host can record it (fail-closed
  // diagnostics) instead of silently running memory-only. The web stub
  // still returns null without an error.
  final dir = directory ?? await getApplicationSupportDirectory();
  final owner = ownerPeerId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final name = owner.isEmpty
      ? 'orbits-hypercore.ndjson'
      : 'orbits-hypercore-$owner.ndjson';
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  if (!file.existsSync()) {
    file.createSync();
  }
  await restrictJournalFileMode(file);
  return FileJournal(
    writerDeviceId: deviceId,
    writeLine: (line) =>
        file.writeAsString('$line\n', mode: FileMode.append, flush: true),
    readLines: () async =>
        file.existsSync() ? file.readAsLinesSync() : const <String>[],
  );
}

/// Best-effort 0600 on the journal file (POSIX only). The JSONL rows
/// carry plaintext metadata (senderIdentity, roomId, memberPeerId) next
/// to ciphertext envelopes; this only narrows local disclosure.
Future<void> restrictJournalFileMode(File file) async {
  if (Platform.isWindows) return;
  try {
    await Process.run('chmod', ['600', file.path]);
  } catch (_) {}
}
