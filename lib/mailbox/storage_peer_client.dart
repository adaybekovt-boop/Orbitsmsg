// HTTP client for a blind storage peer. Ciphertext only.

import 'blind_store.dart';

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

  final Future<void> Function({
    required String token,
    required String writerKey,
    required EncryptedBlock block,
  }) putRemote;

  final Future<List<EncryptedBlock>> Function({
    required String token,
    required String writerKey,
    int fromSeq,
  }) getRemote;

  final Future<void> Function(String token, String writerKey, int seq)?
      tombstoneRemote;

  final Future<void> Function(MailboxCapability cap)? grantRemote;

  final Future<MailboxPeerStats> Function({
    required String token,
    required String writerKey,
  })? statsRemote;

  Future<void> put({
    required String token,
    required String writerKey,
    required EncryptedBlock block,
  }) {
    if (token.isEmpty) {
      throw StateError('anonymous writes are rejected');
    }
    return putRemote(token: token, writerKey: writerKey, block: block);
  }

  Future<List<EncryptedBlock>> get({
    required String token,
    required String writerKey,
    int fromSeq = 0,
  }) {
    if (token.isEmpty) {
      throw StateError('anonymous reads are rejected');
    }
    return getRemote(token: token, writerKey: writerKey, fromSeq: fromSeq);
  }

  Future<void> tombstone(String token, String writerKey, int seq) async {
    if (token.isEmpty) {
      throw StateError('anonymous writes are rejected');
    }
    await tombstoneRemote?.call(token, writerKey, seq);
  }

  Future<void> grant(MailboxCapability cap) async {
    final fn = grantRemote;
    if (fn == null) {
      throw StateError('storage peer cannot grant');
    }
    await fn(cap);
  }

  Future<MailboxPeerStats?> stats({
    required String token,
    required String writerKey,
  }) async {
    final fn = statsRemote;
    if (fn == null) return null;
    if (token.isEmpty) {
      throw StateError('anonymous reads are rejected');
    }
    return fn(token: token, writerKey: writerKey);
  }

  /// In-process peer used by tests and desktop mailbox mode.
  factory StoragePeerClient.local(BlindMailboxStore store) {
    return StoragePeerClient(
      putRemote: ({
        required token,
        required writerKey,
        required block,
      }) async {
        store.put(token: token, writerKey: writerKey, block: block);
      },
      getRemote: ({
        required token,
        required writerKey,
        fromSeq = 0,
      }) async {
        return store.get(
          token: token,
          writerKey: writerKey,
          fromSeq: fromSeq,
        );
      },
      tombstoneRemote: (token, writerKey, seq) async {
        store.tombstone(token, writerKey, seq);
      },
      grantRemote: (cap) async {
        store.grant(cap);
      },
      statsRemote: ({required token, required writerKey}) async {
        return MailboxPeerStats(
          usedBytes: store.usedBytes(writerKey),
          pendingCount: store.pendingCount(writerKey),
        );
      },
    );
  }
}

const Set<String> kStoragePeerForbiddenKeys = {
  'plaintext',
  'text',
  'body',
  'peerId',
  'kek',
  'rootKey',
};

bool storagePeerKeysAreSafe(Map<String, Object?> body) {
  for (final key in body.keys) {
    if (kStoragePeerForbiddenKeys.contains(key)) return false;
  }
  return true;
}

bool storagePeerBodyIsSafe(Map<String, Object?> body) {
  if (!storagePeerKeysAreSafe(body)) return false;
  final token = body['token'];
  final writer = body['writerKey'];
  if (token is! String || token.isEmpty) return false;
  if (writer is! String || writer.isEmpty) return false;
  return body.containsKey('b64') || body.containsKey('seq');
}

bool storagePeerGrantIsSafe(Map<String, Object?> body) {
  if (!storagePeerKeysAreSafe(body)) return false;
  final token = body['token'];
  return token is String && token.isNotEmpty;
}
