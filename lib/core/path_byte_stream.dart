// Open a local filesystem path as a byte stream.
//
// dart:io lives in the `_io` impl so chat / connections stay web-safe.
// Callers must still refuse `://` paths. The web stub always returns null
// — web chat keeps picker bytes + PeerJS base64.

import 'path_byte_stream_stub.dart'
    if (dart.library.io) 'path_byte_stream_io.dart'
    as impl;

/// Size in bytes, or null if the path is missing / not a local file.
int? localPathLength(String path) => impl.localPathLength(path);

/// `File.openRead()` for a local existing path. Null on web or if refused.
Stream<List<int>>? openLocalPathByteStream(String path) =>
    impl.openLocalPathByteStream(path);

/// Ciphertext written to a temp path for Bare/loopback `sendFile`.
/// [firstCipher] is the first chunk envelope for the journal only.
/// [dispose] deletes the temp directory. Never holds `fileKey`.
class CipherPathWrite {
  const CipherPathWrite({
    required this.path,
    required this.sizeBytes,
    required this.plaintextBytes,
    required this.firstCipher,
    required this.chunkCount,
    this.dispose = _noopDispose,
  });

  final String path;
  final int sizeBytes;
  final int plaintextBytes;
  final List<int> firstCipher;
  final int chunkCount;
  final void Function() dispose;

  static void _noopDispose() {}
}

/// Seal a local plaintext path onto a temp ciphertext file (64 KiB
/// plaintext chunks, versioned AEAD envelopes). Null on web / refused
/// paths.
Future<CipherPathWrite?> sealPlaintextPathToCipherFile(
  String plaintextPath,
  List<int> fileKey, {
  required String scope,
  required String fileId,
}) => impl.sealPlaintextPathToCipherFile(
  plaintextPath,
  fileKey,
  scope: scope,
  fileId: fileId,
);

/// Open a local **ciphertext** path back to plaintext. Null on web /
/// refused paths. Does not hold [fileKey] on disk. Caps at 50 MiB
/// plaintext.
Future<List<int>?> openCipherPathToPlaintext(
  String cipherPath,
  List<int> fileKey, {
  required String scope,
  required String fileId,
  int? totalBytes,
}) => impl.openCipherPathToPlaintext(
  cipherPath,
  fileKey,
  scope: scope,
  fileId: fileId,
  totalBytes: totalBytes,
);

/// Open a local ciphertext path onto a temp plaintext file. Null on web
/// / refused paths. Never holds [fileKey] on disk. Deletes the
/// `orbits-att-pt-*` temp directory on failure.
Future<String?> openCipherPathToPlaintextFile(
  String cipherPath,
  List<int> fileKey, {
  required String scope,
  required String fileId,
  int? totalBytes,
}) => impl.openCipherPathToPlaintextFile(
  cipherPath,
  fileKey,
  scope: scope,
  fileId: fileId,
  totalBytes: totalBytes,
);

/// Stream-copy a local file into [destDirectory] without a Dart
/// `Uint8List` of the body. Null on web / refused paths.
Future<String?> copyLocalPathToStableFile(
  String srcPath,
  String destDirectory, {
  String fileName = 'plain.bin',
}) =>
    impl.copyLocalPathToStableFile(srcPath, destDirectory, fileName: fileName);
