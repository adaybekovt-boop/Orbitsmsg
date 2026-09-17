// Host-plaintext room file transfers. Chunks are 64 KiB; the whole file
// is never one base64 `room_msg`. No fileKey — rooms are not E2E.

import 'room_file_store_stub.dart'
    if (dart.library.io) 'room_file_store_io.dart' as impl;

/// Same size as Drop / native attach chunks.
const int kRoomFileChunkBytes = 64 * 1024;

/// ~64 KiB raw after base64. Not the 12 MiB whole-file cap.
const int kMaxRoomFileChunkB64Len = 96 * 1024;

const String kRoomFileChunkType = 'room_file_chunk';

abstract class RoomIncomingFile {
  Future<void> writeChunk(int offset, List<int> bytes);
  bool get isComplete;
  int get nextOffset;
  List<int>? get assembledBytes;
  Future<String?> finish();
  Future<void> close();
}

Future<RoomIncomingFile?> openRoomIncomingFile({
  required String id,
  required String name,
  required int totalBytes,
}) =>
    impl.openRoomIncomingFile(
      id: id,
      name: name,
      totalBytes: totalBytes,
    );
