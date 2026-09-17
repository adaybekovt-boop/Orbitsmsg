import '../core/orbits_drop.dart';

/// Web: in-memory chunks. Native IO override writes to a path.
Future<DropChunkStore> openPeerJsDropStore(
  DropFileMeta meta,
  String peerId,
) async {
  return MemoryDropChunkStore();
}
