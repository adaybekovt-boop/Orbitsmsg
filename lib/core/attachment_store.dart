// Application Support directory for native chat attachment files.
// Web has no filesystem store — PeerJS keeps picker bytes.

import 'attachment_store_stub.dart'
    if (dart.library.io) 'attachment_store_io.dart' as impl;
import 'path_byte_stream.dart';

/// `…/orbits-file-blobs` under Application Support. Null on web or if
/// path_provider is unavailable (unit tests without a plugin).
Future<String?> localAttachmentStoreDir() => impl.localAttachmentStoreDir();

/// Copy [path] into Application Support when a store exists. Falls back
/// to [path] so tests without path_provider still persist a local file.
Future<String> persistLocalAttachmentPath(
  String path, {
  String fileName = 'plain.bin',
  String? storeDir,
}) async {
  final store = storeDir ?? await localAttachmentStoreDir();
  if (store == null || store.contains('://')) return path;
  final copied = await copyLocalPathToStableFile(
    path,
    store,
    fileName: fileName,
  );
  if (copied != null && copied != path) {
    await deleteOrbitsAttPlaintextSource(path);
  }
  return copied ?? path;
}
