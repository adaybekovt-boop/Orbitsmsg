import '../replication/file_journal.dart';

Future<FileJournal?> openLocalFileJournal(String deviceId) async =>
    FileJournal.memory(deviceId);

Future<String?> localWorkletJournalDir() async => null;
