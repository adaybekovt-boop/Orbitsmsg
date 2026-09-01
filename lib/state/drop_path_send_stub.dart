import '../core/orbits_drop.dart';

/// Web has no filesystem path send; the page supplies picker bytes.
Future<String?> sendDropFileFromFilesystem({
  required DropEngine engine,
  required String path,
  required String name,
  required String mime,
  required int sizeBytes,
  required DropSend send,
  Future<void> Function()? waitForDrain,
  String fileId = '',
  String peerId = '',
  int resumeOffset = 0,
}) async {
  return null;
}
