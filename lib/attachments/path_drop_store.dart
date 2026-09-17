// Path-backed [DropChunkStore]. Chunks are written at seq * chunkSize.
// The assembled file is never held as a Dart `Uint8List`.

import 'dart:io';
import 'dart:typed_data';

import '../core/orbits_drop.dart';
import 'path_attachment.dart';

class PathDropChunkStore implements DropChunkStore {
  PathDropChunkStore._(this._incoming, this._chunkSize, this._receivedBytes);

  final IncomingPathAttachment _incoming;
  final int _chunkSize;
  final Set<int> _seqs = {};
  int _receivedBytes;
  bool _closed = false;

  static Future<PathDropChunkStore> open({
    required DropFileMeta meta,
    required Directory directory,
    required int chunkSize,
  }) async {
    final incoming = await IncomingPathAttachment.open(
      id: meta.fileId,
      name: meta.name,
      totalBytes: meta.size,
      sha256hex: meta.hash,
      directory: directory,
    );
    final store = PathDropChunkStore._(
      incoming,
      chunkSize,
      incoming.nextOffset,
    );
    var off = 0;
    while (off + chunkSize <= incoming.nextOffset) {
      store._seqs.add(off ~/ chunkSize);
      off += chunkSize;
    }
    if (incoming.nextOffset > off && incoming.nextOffset == meta.size) {
      store._seqs.add(off ~/ chunkSize);
    }
    return store;
  }

  @override
  int get receivedBytes => _receivedBytes;

  @override
  int get storedChunkCount => _seqs.length;

  @override
  bool hasSeq(int seq) => _seqs.contains(seq);

  @override
  bool get countsTowardMemoryBudget => false;

  @override
  int get resumeOffset => _incoming.nextOffset;

  @override
  String? get localPath => _incoming.path;

  @override
  Future<void> put(int seq, Uint8List payload) async {
    if (_seqs.contains(seq)) return;
    await _incoming.writeChunk(seq * _chunkSize, payload);
    _seqs.add(seq);
    _receivedBytes += payload.length;
  }

  @override
  Future<Uint8List?> assembledBytes() async => null;

  @override
  Future<String> digestHex() async {
    await _incoming.close();
    _closed = true;
    return sha256File(_incoming.path);
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}
