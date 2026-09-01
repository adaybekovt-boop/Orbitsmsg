import '../replication/file_journal.dart';

Future<FileJournal?> openLocalFileJournal(String deviceId) async =>
    FileJournal.memory(deviceId);
