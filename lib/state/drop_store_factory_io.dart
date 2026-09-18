import 'dart:io';

import '../attachments/path_drop_store.dart';
import '../core/orbits_drop.dart';

Directory? _dropIncomingDir;

Future<Directory> peerJsDropIncomingDir() async {
  final existing = _dropIncomingDir;
  if (existing != null && existing.existsSync()) return existing;
  final created = await Directory.systemTemp.createTemp('orbits-drop-in-');
  _dropIncomingDir = created;
  return created;
}

Future<DropChunkStore> openPeerJsDropStore(
  DropFileMeta meta,
  String peerId,
) async {
  final dir = await peerJsDropIncomingDir();
  return PathDropChunkStore.open(
    meta: meta,
    directory: dir,
    chunkSize: dropChunkSize,
  );
}
