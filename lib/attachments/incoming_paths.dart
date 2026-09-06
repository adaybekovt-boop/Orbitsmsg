// Safe incoming file layout:
// incoming/<trusted-sender-id>/<local-transfer-id>/blob
// External transfer IDs are never used as path fragments.

import 'dart:io';
import 'dart:math';

import '../peer/helpers.dart';

final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
final _winDrive = RegExp(r'^[a-zA-Z]:[\\/]');
final _encodedDotDot = RegExp(r'%2e%2e|%2E%2E|%252e|%c0%ae', caseSensitive: false);

String generateLocalTransferId() {
  final rng = Random.secure();
  return List<int>.generate(16, (_) => rng.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

String assertSafePathFragment(String raw, {required String label}) {
  final value = raw.trim();
  if (value.isEmpty) {
    throw StateError('unsafe-$label');
  }
  if (value.contains('\u0000') ||
      value.contains('..') ||
      _encodedDotDot.hasMatch(value) ||
      value.contains('/') ||
      value.contains('\\') ||
      value.contains(':') ||
      _winDrive.hasMatch(value)) {
    throw StateError('unsafe-$label');
  }
  if (!_safeId.hasMatch(value)) {
    throw StateError('unsafe-$label-format');
  }
  return value;
}

String trustedSenderDirName(String peerId) {
  final norm = normalizePeerId(peerId);
  if (norm.isEmpty) {
    throw StateError('unsafe-sender-id');
  }
  return assertSafePathFragment(norm.replaceAll(':', '_'), label: 'sender-id');
}

Directory incomingRoot(Directory base) {
  return Directory(
    '${base.path}${Platform.pathSeparator}orbits-incoming',
  );
}

Directory resolveIncomingDir({
  required Directory base,
  required String trustedSenderId,
  required String localTransferId,
}) {
  final sender = trustedSenderDirName(trustedSenderId);
  final local = assertSafePathFragment(localTransferId, label: 'local-id');
  final root = incomingRoot(base);
  final dest = Directory(
    '${root.path}${Platform.pathSeparator}$sender${Platform.pathSeparator}$local',
  );
  assertInsideRoot(root, dest);
  return dest;
}

void assertInsideRoot(Directory root, FileSystemEntity candidate) {
  final rootPath = root.absolute.path;
  final candidatePath = candidate.absolute.path;
  final prefix = rootPath.endsWith(Platform.pathSeparator)
      ? rootPath
      : '$rootPath${Platform.pathSeparator}';
  if (candidatePath != rootPath && !candidatePath.startsWith(prefix)) {
    throw StateError('path-escape');
  }
}

File blobFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}blob');

File metaFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}meta.json');
