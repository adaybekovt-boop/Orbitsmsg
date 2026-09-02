// HTTP client for a blind storage peer. Capability hashes and
// sealed blobs only — never peerId, writerKey, or plaintext.

import 'dart:collection';
import 'dart:typed_data';

import '../transport/layers.dart';
import 'blind_store.dart';
import 'mailbox_capability.dart';

/// Opaque queue / cap string. A URL or a secret-field fragment is
/// not a mailbox address. Same rules as [mailboxCapStringIsSafe].
bool storagePeerTokenIsSafe(String token) => mailboxCapStringIsSafe(token);

void _assertQueueId(String queueId, {required String emptyMessage}) {
  if (queueId.isEmpty) {
    throw StateError(emptyMessage);
  }
  if (!mailboxCapStringIsSafe(queueId)) {
    throw StateError('unsafe mailbox queue');
  }
}

class MailboxPeerStats {
  const MailboxPeerStats({required this.usedBytes, required this.pendingCount});

  final int usedBytes;
  final int pendingCount;
}

class StoragePeerClient {
  StoragePeerClient({
    required this.putRemote,
    required this.getRemote,
    this.tombstoneRemote,
    this.grantRemote,
    this.statsRemote,
  });

  final Future<EncryptedBlock> Function({
    required String queueId,
    required List<int> depositCap,
    required List<int> bytes,
    required String blockHash,
  }) putRemote;

  final Future<List<EncryptedBlock>> Function({
    required String queueId,
    required List<int> readCap,
    int fromSeq,
  }) getRemote;

  final Future<void> Function({
    required String queueId,
    required List<int> readCap,
    required int seq,
  })? tombstoneRemote;

  final Future<void> Function({
    required MailboxCapability cap,
    List<int>? readCap,
    String? adminToken,
  })? grantRemote;

  final Future<MailboxPeerStats> Function({
    required String queueId,
    required List<int> readCap,
  })? statsRemote;

  Future<EncryptedBlock> put({
    required String queueId,
    required List<int> depositCap,
    required List<int> bytes,
    String? blockHash,
  }) {
    _assertQueueId(queueId, emptyMessage: 'anonymous writes are rejected');
    if (depositCap.length != kMailboxCapBytes) {
      throw StateError('invalid deposit capability');
    }
    if (bytes.isEmpty) {
      throw StateError('empty mailbox envelope');
    }
    return putRemote(
      queueId: queueId,
      depositCap: depositCap,
      bytes: bytes,
      blockHash: blockHash ?? sha256HexOf(bytes),
    );
  }

  Future<List<EncryptedBlock>> get({
    required String queueId,
    required List<int> readCap,
    int fromSeq = 0,
  }) {
    _assertQueueId(queueId, emptyMessage: 'anonymous reads are rejected');
    if (readCap.length != kMailboxCapBytes) {
      throw StateError('invalid read capability');
    }
    return getRemote(queueId: queueId, readCap: readCap, fromSeq: fromSeq);
  }

  Future<void> tombstone({
    required String queueId,
    required List<int> readCap,
    required int seq,
  }) async {
    _assertQueueId(queueId, emptyMessage: 'anonymous writes are rejected');
    if (readCap.length != kMailboxCapBytes) {
      throw StateError('invalid read capability');
    }
    await tombstoneRemote?.call(
      queueId: queueId,
      readCap: readCap,
      seq: seq,
    );
  }

  Future<void> grant({
    required MailboxCapability cap,
    List<int>? readCap,
    String? adminToken,
  }) async {
    final fn = grantRemote;
    if (fn == null) {
      throw StateError('storage peer cannot grant');
    }
    if (!mailboxCapStringIsSafe(cap.queueId)) {
      throw StateError('unsafe mailbox queue');
    }
    await fn(cap: cap, readCap: readCap, adminToken: adminToken);
  }

  Future<MailboxPeerStats?> stats({
    required String queueId,
    required List<int> readCap,
  }) async {
    final fn = statsRemote;
    if (fn == null) return null;
    _assertQueueId(queueId, emptyMessage: 'anonymous reads are rejected');
    if (readCap.length != kMailboxCapBytes) {
      throw StateError('invalid read capability');
    }
    return fn(queueId: queueId, readCap: readCap);
  }

  /// In-process peer used by tests and desktop mailbox mode.
  factory StoragePeerClient.local(
    BlindMailboxStore store, {
    String? adminToken,
  }) {
    return StoragePeerClient(
      putRemote: ({
        required queueId,
        required depositCap,
        required bytes,
        required blockHash,
      }) async {
        return store.put(
          queueId: queueId,
          depositCap: depositCap,
          bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
          blockHash: blockHash,
        );
      },
      getRemote: ({
        required queueId,
        required readCap,
        fromSeq = 0,
      }) async {
        return store.get(
          queueId: queueId,
          readCap: readCap,
          fromSeq: fromSeq,
        );
      },
      tombstoneRemote: ({
        required queueId,
        required readCap,
        required seq,
      }) async {
        store.tombstone(queueId: queueId, readCap: readCap, seq: seq);
      },
      grantRemote: ({required cap, readCap, adminToken}) async {
        store.grant(
          queueId: cap.queueId,
          readCapHash: cap.readCapHash,
          depositCapHash: cap.depositCapHash,
          quotaBytes: cap.quotaBytes,
          retentionMs: cap.retentionMs,
          expiresAt: cap.expiresAt,
          readCap: readCap,
          adminOk: adminToken != null && adminToken.isNotEmpty,
        );
      },
      statsRemote: ({required queueId, required readCap}) async {
        final raw = store.stats(queueId: queueId, readCap: readCap);
        return MailboxPeerStats(
          usedBytes: (raw['bytes'] as num?)?.toInt() ?? 0,
          pendingCount: (raw['blocks'] as num?)?.toInt() ?? 0,
        );
      },
    );
  }
}

const Set<String> kStoragePeerForbiddenKeys = {
  ...kForbiddenReplicationFields,
  'text',
  'body',
  'peerId',
  'writerKey',
  'conversationId',
};

/// Rejects [kStoragePeerForbiddenKeys] at any depth. [bytes] / [b64] allowed.
/// Walks nested [Map] / [Iterable] with identity-based cycle detection.
bool storagePeerKeysAreSafe(Map<String, Object?> body) {
  return _storagePeerValueIsSafe(body, HashSet<Object>.identity());
}

bool _storagePeerValueIsSafe(Object? value, Set<Object> seen) {
  if (value == null || value is bool || value is num || value is String) {
    return true;
  }
  if (value is Map) {
    if (!seen.add(value)) return true;
    for (final key in value.keys) {
      if (kStoragePeerForbiddenKeys.contains('$key')) return false;
    }
    for (final nested in value.values) {
      if (!_storagePeerValueIsSafe(nested, seen)) return false;
    }
    return true;
  }
  if (value is Iterable) {
    if (!seen.add(value)) return true;
    for (final nested in value) {
      if (!_storagePeerValueIsSafe(nested, seen)) return false;
    }
    return true;
  }
  return true;
}

bool _hex64(Object? value) =>
    value is String && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);

bool storagePeerBodyIsSafe(Map<String, Object?> body) {
  if (!storagePeerKeysAreSafe(body)) return false;
  if (body.containsKey('token') || body.containsKey('writerKey')) return false;
  if (!_hex64(body['queueId'])) return false;
  if (!_hex64(body['depositCap'])) return false;
  final block = body['block'];
  if (block is! Map) return false;
  final typed = Map<String, Object?>.from(block);
  if (!storagePeerKeysAreSafe(typed)) return false;
  final bytes = typed['bytes'] ?? typed['b64'];
  final hash = typed['blockHash'];
  return bytes is String && bytes.isNotEmpty && _hex64(hash);
}

bool storagePeerGrantIsSafe(Map<String, Object?> body) {
  if (!storagePeerKeysAreSafe(body)) return false;
  if (body.containsKey('token') || body.containsKey('writerKey')) return false;
  if (!_hex64(body['queueId'])) return false;
  if (!_hex64(body['readCapHash'])) return false;
  if (!_hex64(body['depositCapHash'])) return false;
  final readCap = body['readCap'];
  if (readCap != null && !_hex64(readCap)) return false;
  return true;
}

bool storagePeerReadQueryIsSafe({
  required String queueId,
  required String readCap,
}) {
  return _hex64(queueId) &&
      _hex64(readCap) &&
      mailboxCapStringIsSafe(queueId) &&
      mailboxCapStringIsSafe(readCap);
}
