// Sender deposits encrypted envelopes; recipient fetches after the
// sender is gone. The store never receives keys or plaintext.

import 'blind_store.dart';
import 'storage_peer_client.dart';

class MailboxPump {
  int _seq = 0;

  void deposit({
    required BlindMailboxStore store,
    required String token,
    required String writerKey,
    required List<int> encryptedEnvelope,
  }) {
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
    return store.get(token: token, writerKey: writerKey, fromSeq: fromSeq);
  }

  Future<void> depositClient({
    required StoragePeerClient client,
    required String token,
    required String writerKey,
    required List<int> encryptedEnvelope,
  }) async {
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
    return client.get(token: token, writerKey: writerKey, fromSeq: fromSeq);
  }
}
