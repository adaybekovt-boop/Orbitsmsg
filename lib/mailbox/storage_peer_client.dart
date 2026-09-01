// HTTP client for a blind storage peer. Ciphertext only.

import 'blind_store.dart';

class StoragePeerClient {
  StoragePeerClient({
    required this.putRemote,
    required this.getRemote,
    this.tombstoneRemote,
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

  Future<void> put({
    required String token,
    required String writerKey,
    required EncryptedBlock block,
  }) {
    return putRemote(token: token, writerKey: writerKey, block: block);
  }

  Future<List<EncryptedBlock>> get({
    required String token,
    required String writerKey,
    int fromSeq = 0,
  }) {
    return getRemote(token: token, writerKey: writerKey, fromSeq: fromSeq);
  }

  Future<void> tombstone(String token, String writerKey, int seq) async {
    await tombstoneRemote?.call(token, writerKey, seq);
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

bool storagePeerBodyIsSafe(Map<String, Object?> body) {
  for (final key in body.keys) {
    if (kStoragePeerForbiddenKeys.contains(key)) return false;
  }
  return body.containsKey('token') &&
      body.containsKey('writerKey') &&
      (body.containsKey('b64') || body.containsKey('seq'));
}
