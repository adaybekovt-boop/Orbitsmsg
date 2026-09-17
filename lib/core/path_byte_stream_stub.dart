// Web / no-io: there is no filesystem path to stream.

import 'path_byte_stream.dart';

int? localPathLength(String path) => null;

Stream<List<int>>? openLocalPathByteStream(String path) => null;

Future<CipherPathWrite?> xorPlaintextPathToCipherFile(
  String plaintextPath,
  List<int> fileKey,
) async =>
    null;

Future<List<int>?> xorCipherPathToPlaintext(
  String cipherPath,
  List<int> fileKey,
) async =>
    null;

Future<String?> xorCipherPathToPlaintextFile(
  String cipherPath,
  List<int> fileKey,
) async =>
    null;

Future<String?> copyLocalPathToStableFile(
  String srcPath,
  String destDirectory, {
  String fileName = 'plain.bin',
}) async =>
    null;

Future<String?> writeBytesToTempPath(
  List<int> bytes, {
  String fileName = 'plain.bin',
  int maxBytes = 50 * 1024 * 1024,
}) async =>
    null;

Future<String?> openInboundCipherPath(String fileId) async => null;

Future<bool> writeInboundCipherChunk(
  String fileId,
  int offset,
  List<int> bytes,
) async =>
    false;
