import '../replication/file_journal.dart';

/// Web has no dart:io journal. [ownerPeerId] must stay in the signature so
/// dart2js can compile the IO host against this stub. Returning null forces
/// a fresh in-memory journal instead of a fake durable store.
Future<FileJournal?> openLocalFileJournal(
  String deviceId, {
  String ownerPeerId = '',
}) async {
  // Parameters document the IO contract; web cannot persist either value.
  return null;
}
