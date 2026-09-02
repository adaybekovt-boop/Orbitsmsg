// Web / no-io: there is no filesystem path to stream.

import 'path_byte_stream.dart';

int? localPathLength(String path) => null;

Stream<List<int>>? openLocalPathByteStream(String path) => null;

Future<CipherPathWrite?> sealPlaintextPathToCipherFile(
  String plaintextPath,
  List<int> fileKey, {
  required String scope,
  required String fileId,
}) async => null;

Future<List<int>?> openCipherPathToPlaintext(
  String cipherPath,
  List<int> fileKey, {
  required String scope,
  required String fileId,
  int? totalBytes,
}) async => null;

Future<String?> openCipherPathToPlaintextFile(
  String cipherPath,
  List<int> fileKey, {
  required String scope,
  required String fileId,
  int? totalBytes,
}) async => null;

Future<String?> copyLocalPathToStableFile(
  String srcPath,
  String destDirectory, {
  String fileName = 'plain.bin',
}) async => null;

Future<void> deleteOrbitsAttPlaintextSource(String path) async {}
