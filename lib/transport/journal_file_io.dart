import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../replication/file_journal.dart';

Future<FileJournal?> openLocalFileJournal(
  String deviceId, {
  String ownerPeerId = '',
}) async {
  try {
    final dir = await getApplicationSupportDirectory();
    final owner = ownerPeerId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final name = owner.isEmpty
        ? 'orbits-hypercore.ndjson'
        : 'orbits-hypercore-$owner.ndjson';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
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
