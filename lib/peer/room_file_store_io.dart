import '../attachments/path_attachment.dart';
import 'room_file_store.dart';

class _PathRoomIncomingFile implements RoomIncomingFile {
  _PathRoomIncomingFile(this._inner);

  final IncomingPathAttachment _inner;

  @override
  Future<void> writeChunk(int offset, List<int> bytes) =>
      _inner.writeChunk(offset, bytes);

  @override
  bool get isComplete => _inner.isComplete;

  @override
  int get nextOffset => _inner.nextOffset;

  @override
  List<int>? get assembledBytes => null;

  @override
  Future<String?> finish() async {
    final result = await _inner.complete();
    return result?.path;
  }

  @override
  Future<void> close() => _inner.close();
}

Future<RoomIncomingFile?> openRoomIncomingFile({
  required String id,
  required String name,
  required int totalBytes,
}) async {
  if (id.isEmpty || totalBytes <= 0) return null;
  final inner = await IncomingPathAttachment.open(
    id: id,
    name: name,
    totalBytes: totalBytes,
    sha256hex: '',
  );
  return _PathRoomIncomingFile(inner);
}
