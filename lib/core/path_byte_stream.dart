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

/// XOR a local **ciphertext** path back to plaintext. Null on web /
/// refused paths. Does not hold [fileKey] on disk. Caps at 50 MiB.
Future<List<int>?> xorCipherPathToPlaintext(
  String cipherPath,
  List<int> fileKey,
) =>
    impl.xorCipherPathToPlaintext(cipherPath, fileKey);

/// XOR a local ciphertext path onto a temp plaintext file. Null on web
/// / refused paths. Never holds [fileKey] on disk.
Future<String?> xorCipherPathToPlaintextFile(
  String cipherPath,
  List<int> fileKey,
) =>
    impl.xorCipherPathToPlaintextFile(cipherPath, fileKey);

/// Stream-copy a local file into [destDirectory] without a Dart
/// `Uint8List` of the body. Null on web / refused paths.
Future<String?> copyLocalPathToStableFile(
  String srcPath,
  String destDirectory, {
  String fileName = 'plain.bin',
}) =>
    impl.copyLocalPathToStableFile(
      srcPath,
      destDirectory,
      fileName: fileName,
    );
