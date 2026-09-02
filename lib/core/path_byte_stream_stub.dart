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
