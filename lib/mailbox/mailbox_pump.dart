// Sender deposits encrypted envelopes; recipient fetches after the
// sender is gone. The store never receives keys or plaintext.

import 'blind_store.dart';
import 'storage_peer_client.dart';

/// Capability tokens are opaque. Same rules as [storagePeerTokenIsSafe].
bool mailboxPumpTokenIsSafe(String token) => storagePeerTokenIsSafe(token);

void _assertMailboxPumpArgs({
  required String token,
  required String writerKey,
  List<int>? encryptedEnvelope,
}) {
  if (!mailboxPumpTokenIsSafe(token)) {
    throw StateError('unsafe mailbox token');
  }
  if (writerKey.isEmpty) {
    throw StateError('empty mailbox writer');
  }
  if (encryptedEnvelope != null && encryptedEnvelope.isEmpty) {
    throw StateError('empty mailbox envelope');
  }
}

class MailboxPump {
  int _seq = 0;

  void deposit({
    required BlindMailboxStore store,
    required String token,
    required String writerKey,
    required List<int> encryptedEnvelope,
  }) {
    _assertMailboxPumpArgs(
      token: token,
      writerKey: writerKey,
      encryptedEnvelope: encryptedEnvelope,
    );
    store.put(
      token: token,
      writerKey: writerKey,
      block: EncryptedBlock(
        seq: _seq++,
        bytes: List<int>.from(encryptedEnvelope),
        storedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  List<EncryptedBlock> collect({
    required BlindMailboxStore store,
    required String token,
    required String writerKey,
    int fromSeq = 0,
  }) {
    _assertMailboxPumpArgs(token: token, writerKey: writerKey);
    return store.get(token: token, writerKey: writerKey, fromSeq: fromSeq);
  }

  Future<void> depositClient({
    required StoragePeerClient client,
    required String token,
    required String writerKey,
    required List<int> encryptedEnvelope,
  }) async {
    _assertMailboxPumpArgs(
      token: token,
      writerKey: writerKey,
      encryptedEnvelope: encryptedEnvelope,
    );
    final seq = _seq;
    await client.put(
      token: token,
      writerKey: writerKey,
      block: EncryptedBlock(
        seq: seq,
        bytes: List<int>.from(encryptedEnvelope),
        storedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _seq = seq + 1;
  }

  Future<List<EncryptedBlock>> collectClient({
    required StoragePeerClient client,
    required String token,
    required String writerKey,
    int fromSeq = 0,
  }) {
    _assertMailboxPumpArgs(token: token, writerKey: writerKey);
    return client.get(token: token, writerKey: writerKey, fromSeq: fromSeq);
  }
}
