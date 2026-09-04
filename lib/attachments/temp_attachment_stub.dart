import '../transport/transport_api.dart';

Future<TransportFileDescriptor?> writeTempAttachment({
  required List<int> bytes,
  required String name,
  required String mime,
}) async {
  return null;
}

Future<List<int>?> readAttachmentPath(String path) async => null;

Future<List<int>?> readIncomingTransfer({
  required String transferId,
  required String name,
}) async =>
    null;

Future<void> deleteTempAttachment(String? path) async {}
