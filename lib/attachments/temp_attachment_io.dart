import 'dart:io';

import '../transport/transport_api.dart';

Future<TransportFileDescriptor?> writeTempAttachment({
  required List<int> bytes,
  required String name,
  required String mime,
}) async {
  final dir = Directory.systemTemp.createTempSync('orbits-chat-file-');
  final safe = name.replaceAll(RegExp(r'[\x00-\x1f\\/:*?"<>|]'), '_');
  final file = File('${dir.path}${Platform.pathSeparator}$safe');
  await file.writeAsBytes(bytes, flush: true);
  return TransportFileDescriptor(
    path: file.path,
    sizeBytes: bytes.length,
    fileName: safe,
    mime: mime,
  );
}

Future<List<int>?> readAttachmentPath(String path) async {
  final file = File(path);
  if (!file.existsSync()) return null;
  return file.readAsBytes();
}

Future<List<int>?> readIncomingTransfer({
  required String transferId,
  required String name,
}) async {
  final safeId = transferId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final safeName = name.replaceAll(RegExp(r'[\x00-\x1f\\/:*?"<>|]'), '_');
  if (safeId.isEmpty || safeName.isEmpty) return null;
  final path =
      '${Directory.systemTemp.path}${Platform.pathSeparator}orbits-incoming${Platform.pathSeparator}$safeId${Platform.pathSeparator}$safeName';
  return readAttachmentPath(path);
}
