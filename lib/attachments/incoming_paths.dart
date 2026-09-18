// Safe incoming file layout:
// incoming/<trusted-sender-id>/<local-transfer-id>/blob
// External transfer IDs are never used as path fragments.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../peer/helpers.dart';

final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
final _winDrive = RegExp(r'^[a-zA-Z]:[\\/]');
final _encodedDotDot = RegExp(
  r'%2e%2e|%2E%2E|%252e|%c0%ae',
  caseSensitive: false,
);

String generateLocalTransferId() {
  final rng = Random.secure();
  return List<int>.generate(
    16,
    (_) => rng.nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
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
  return Directory('${base.path}${Platform.pathSeparator}orbits-incoming');
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

/// Resolve a completed incoming blob. Prefers the current jail
/// (`sender/local-id/blob`), then a meta.json scan by external transfer
/// id, then the legacy `orbits-incoming/<transferId>/<name>` layout.
File? lookupIncomingBlob({
  required Directory base,
  String? trustedSenderId,
  String? localTransferId,
  String? externalTransferId,
  String? legacyName,
}) {
  if (trustedSenderId != null &&
      trustedSenderId.isNotEmpty &&
      localTransferId != null &&
      localTransferId.isNotEmpty) {
    try {
      final dir = resolveIncomingDir(
        base: base,
        trustedSenderId: trustedSenderId,
        localTransferId: localTransferId,
      );
      final blob = blobFile(dir);
      if (_isRegularFile(blob)) return blob;
    } catch (_) {}
  }

  if (trustedSenderId != null &&
      trustedSenderId.isNotEmpty &&
      externalTransferId != null &&
      externalTransferId.isNotEmpty) {
    try {
      final sender = trustedSenderDirName(trustedSenderId);
      final root = Directory(
        '${incomingRoot(base).path}${Platform.pathSeparator}$sender',
      );
      if (root.existsSync()) {
        for (final entity in root.listSync()) {
          if (entity is! Directory) continue;
          final meta = metaFile(entity);
          if (!meta.existsSync()) continue;
          try {
            final prev = Map<String, Object?>.from(
              jsonDecode(meta.readAsStringSync()) as Map,
            );
            if (prev['externalTransferId'] == externalTransferId &&
                prev['trustedSender'] == sender) {
              final blob = blobFile(entity);
              assertInsideRoot(incomingRoot(base), blob);
              if (_isRegularFile(blob)) return blob;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  if (externalTransferId != null &&
      externalTransferId.isNotEmpty &&
      legacyName != null &&
      legacyName.isNotEmpty) {
    try {
      final safeId = assertSafePathFragment(
        externalTransferId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_'),
        label: 'legacy-id',
      );
      final safeName = legacyName.replaceAll(
        RegExp(r'[\x00-\x1f\\/:*?"<>|]'),
        '_',
      );
      if (safeName.isEmpty || safeName == '.' || safeName == '..') {
        return null;
      }
      final file = File(
        '${incomingRoot(base).path}${Platform.pathSeparator}$safeId${Platform.pathSeparator}$safeName',
      );
      assertInsideRoot(incomingRoot(base), file);
      if (_isRegularFile(file)) return file;
    } catch (_) {}
  }
  return null;
}

bool _isRegularFile(File file) {
  return file.existsSync() && file.statSync().type == FileSystemEntityType.file;
}
