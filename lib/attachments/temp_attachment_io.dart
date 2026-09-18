import 'dart:io';

import '../transport/transport_api.dart';
import 'incoming_paths.dart';

export 'incoming_paths.dart' show isAllowedAttachmentPath;

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
  if (!isAllowedAttachmentPath(path)) return null;
  final file = File(path);
  if (!file.existsSync()) return null;
  return file.readAsBytes();
}

String? lookupIncomingTransferPath({
  required String transferId,
  required String name,
  String? trustedSenderId,
  Directory? base,
}) {
  if (trustedSenderId == null || trustedSenderId.isEmpty) return null;
  final sanitized = trySanitizeTransferId(transferId);
  final alreadySafe = sanitized != null && sanitized == transferId.trim();
  final found = lookupIncomingBlob(
    base: base ?? Directory.systemTemp,
    trustedSenderId: trustedSenderId,
    // Chat `msgId` (`ORBIT-…:ts:short`) is an external id, never the
    // receiver-local jail directory. Only already-safe fragments (the
    // 32-hex local id) may be tried as [localTransferId].
    localTransferId: alreadySafe ? sanitized : null,
    externalTransferId: transferId,
  );
  return found?.path;
}

Future<List<int>?> readIncomingTransfer({
  required String transferId,
  required String name,
  String? trustedSenderId,
  Directory? base,
}) async {
  final path = lookupIncomingTransferPath(
    transferId: transferId,
    name: name,
    trustedSenderId: trustedSenderId,
    base: base,
  );
  if (path == null) return null;
  return readAttachmentPath(path);
}

Future<void> deleteTempAttachment(String? path) async {
  if (path == null || path.isEmpty) return;
  try {
    final file = File(path);
    if (file.existsSync()) await file.delete();
    final parent = file.parent;
    if (parent.path.contains('orbits-chat-file-') && parent.existsSync()) {
      if (parent.listSync().isEmpty) await parent.delete();
    }
  } catch (_) {}
}
