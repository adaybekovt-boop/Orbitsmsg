// Safe incoming file layout:
// incoming/<trusted-sender-id>/<local-transfer-id>/blob
// External transfer IDs are never used as path fragments.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../peer/helpers.dart';
import 'transfer_id.dart';

export 'transfer_id.dart';

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

String resolvedJailPath(FileSystemEntity entity) {
  try {
    if (entity.existsSync()) {
      return entity.resolveSymbolicLinksSync();
    }
    final parent = entity.parent;
    if (parent.existsSync()) {
      final segments =
          entity.uri.pathSegments.where((s) => s.isNotEmpty).toList();
      final leaf = segments.isEmpty ? '' : segments.last;
      return '${parent.resolveSymbolicLinksSync()}'
          '${Platform.pathSeparator}$leaf';
    }
  } catch (_) {}
  return entity.absolute.path;
}

void assertInsideRoot(Directory root, FileSystemEntity candidate) {
  final rootPath = resolvedJailPath(root);
  final candidatePath = resolvedJailPath(candidate);
  final prefix = rootPath.endsWith(Platform.pathSeparator)
      ? rootPath
      : '$rootPath${Platform.pathSeparator}';
  if (candidatePath != rootPath && !candidatePath.startsWith(prefix)) {
    throw StateError('path-escape');
  }
}

bool _isRegularExistingFile(File file) {
  return file.existsSync() && file.statSync().type == FileSystemEntityType.file;
}

/// Fail-closed allowlist for path-backed blobs: the incoming jail or an
/// `orbits-chat-file-*` temp dir, after symlink resolution.
bool isAllowedAttachmentPath(String path, {Directory? incomingBase}) {
  if (path.isEmpty || path.contains('\u0000')) return false;
  final file = File(path);
  if (!_isRegularExistingFile(file)) return false;
  final File resolved;
  try {
    resolved = File(file.resolveSymbolicLinksSync());
  } catch (_) {
    return false;
  }
  if (!_isRegularExistingFile(resolved)) return false;

  final bases = <Directory>{
    incomingBase ?? Directory.systemTemp,
    Directory.systemTemp,
  };
  for (final base in bases) {
    try {
      assertInsideRoot(incomingRoot(base), resolved);
      return true;
    } catch (_) {}
  }

  Directory cursor = resolved.parent;
  for (var i = 0; i < 8; i++) {
    final segments =
        cursor.uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final name = segments.isEmpty ? cursor.path : segments.last;
    if (name.startsWith('orbits-chat-file-')) {
      try {
        assertInsideRoot(cursor, resolved);
        return true;
      } catch (_) {
        return false;
      }
    }
    final parent = cursor.parent;
    if (parent.path == cursor.path) break;
    cursor = parent;
  }
  return false;
}

File blobFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}blob');

File metaFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}meta.json');

/// Resolve a completed incoming blob. Prefers the current jail
/// (`sender/local-id/blob`), then a meta.json scan by external transfer
/// id. Requires [trustedSenderId]: the sender-less legacy
/// `orbits-incoming/<transferId>/<name>` layout was removed — a remote
/// peer must not reach another sender's jail through it.
File? lookupIncomingBlob({
  required Directory base,
  String? trustedSenderId,
  String? localTransferId,
  String? externalTransferId,
}) {
  if (trustedSenderId == null || trustedSenderId.isEmpty) return null;
  if (localTransferId != null && localTransferId.isNotEmpty) {
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

  if (externalTransferId != null && externalTransferId.isNotEmpty) {
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
            if (transferIdsMatch(
                  prev['externalTransferId'] as String?,
                  externalTransferId,
                ) &&
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
  return null;
}

bool _isRegularFile(File file) {
  return file.existsSync() && file.statSync().type == FileSystemEntityType.file;
}
