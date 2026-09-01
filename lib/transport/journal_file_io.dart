import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../replication/file_journal.dart';

Future<FileJournal?> openLocalFileJournal(String deviceId) async {
  try {
    final dir = await getApplicationSupportDirectory();
    final file = File(
      '${dir.path}${Platform.pathSeparator}orbits-hypercore.ndjson',
    );
    return FileJournal(
      writerDeviceId: deviceId,
      writeLine: (line) =>
          file.writeAsString('$line\n', mode: FileMode.append, flush: true),
      readLines: () async =>
          file.existsSync() ? file.readAsLinesSync() : const <String>[],
    );
  } catch (_) {
    return null;
  }
}

/// Local Corestore / JSONL directory for the worklet journal.
/// Sibling of `orbits-hypercore.ndjson`. Never a remote URL.
Future<String?> localWorkletJournalDir() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final root = Directory(
      '${dir.path}${Platform.pathSeparator}orbits-corestore',
    );
    root.createSync(recursive: true);
    return root.path;
  } catch (_) {
    return null;
  }
}
