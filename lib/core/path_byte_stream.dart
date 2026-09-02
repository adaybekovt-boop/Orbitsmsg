// Open a local filesystem path as a byte stream.
//
// dart:io lives in the `_io` impl so chat / connections stay web-safe.
// Callers must still refuse `://` paths. The web stub always returns null
// — web chat keeps picker bytes + PeerJS base64.

import 'path_byte_stream_stub.dart'
    if (dart.library.io) 'path_byte_stream_io.dart' as impl;

/// Size in bytes, or null if the path is missing / not a local file.
int? localPathLength(String path) => impl.localPathLength(path);

/// `File.openRead()` for a local existing path. Null on web or if refused.
Stream<List<int>>? openLocalPathByteStream(String path) =>
    impl.openLocalPathByteStream(path);

/// Ciphertext written to a temp path for Bare/loopback `sendFile`.
/// [firstCipher] is the first 64 KiB for the journal only. [dispose]
/// deletes the temp directory. Never holds `fileKey`.
class CipherPathWrite {
  const CipherPathWrite({
    required this.path,
    required this.sizeBytes,
    required this.firstCipher,
    required this.chunkCount,
    this.dispose = _noopDispose,
  });

  final String path;
  final int sizeBytes;
  final List<int> firstCipher;
  final int chunkCount;
  final void Function() dispose;

  static void _noopDispose() {}
}

/// XOR a local plaintext path onto a temp ciphertext file (64 KiB
/// chunks). Null on web / refused paths.
Future<CipherPathWrite?> xorPlaintextPathToCipherFile(
  String plaintextPath,
  List<int> fileKey,
) =>
    impl.xorPlaintextPathToCipherFile(plaintextPath, fileKey);
