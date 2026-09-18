import '../transport/transport_api.dart';

Future<TransportFileDescriptor?> writeTempAttachment({
  required List<int> bytes,
  required String name,
  required String mime,
}) async {
  return null;
}

Future<List<int>?> readAttachmentPath(
  String path, {
  int maxBytes = 50 * 1024 * 1024,
}) async =>
    null;

bool isAllowedAttachmentPath(String path, {Object? incomingBase}) => false;

int attachmentPathSize(String path) => -1;

String? lookupIncomingTransferPath({
  required String transferId,
  required String name,
  String? trustedSenderId,
  Object? base,
}) =>
    null;

Future<List<int>?> readIncomingTransfer({
  required String transferId,
  required String name,
  String? trustedSenderId,
  Object? base,
}) async =>
    null;

Future<void> deleteTempAttachment(String? path) async {}
