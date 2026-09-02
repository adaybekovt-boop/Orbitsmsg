import 'dart:typed_data';

import 'room_file_store.dart';

class _MemoryRoomIncomingFile implements RoomIncomingFile {
  _MemoryRoomIncomingFile({required this.totalBytes});

  final int totalBytes;
  final BytesBuilder _buf = BytesBuilder(copy: false);

  @override
  Future<void> writeChunk(int offset, List<int> bytes) async {
    if (bytes.isEmpty) return;
    if (offset != _buf.length) return;
    if (_buf.length + bytes.length > totalBytes) return;
    _buf.add(bytes);
  }

  @override
  bool get isComplete => _buf.length >= totalBytes && totalBytes > 0;

  @override
  int get nextOffset => _buf.length;

  @override
  List<int>? get assembledBytes =>
      isComplete ? _buf.toBytes() : null;

  @override
  Future<String?> finish() async {
    if (!isComplete) return null;
    return null;
  }

  @override
  Future<void> close() async {}
}

Future<RoomIncomingFile?> openRoomIncomingFile({
  required String id,
  required String name,
  required int totalBytes,
}) async {
  if (id.isEmpty || totalBytes <= 0) return null;
  return _MemoryRoomIncomingFile(totalBytes: totalBytes);
}
