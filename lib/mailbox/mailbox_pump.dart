// Sender deposits encrypted envelopes; recipient fetches after the
// sender is gone. The store never receives keys or plaintext.

import 'blind_store.dart';

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
}
