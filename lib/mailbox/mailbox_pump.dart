// Sender deposits sealed envelopes into the RECIPIENT queue.
// Recipient collects with readCap. Storage never sees keys or plaintext.

import 'dart:typed_data';

import 'blind_store.dart';
import 'mailbox_capability.dart';
import 'storage_peer_client.dart';

/// Opaque capability / queue id. Same rules as [mailboxCapStringIsSafe].
bool mailboxPumpTokenIsSafe(String token) => mailboxCapStringIsSafe(token);

void _assertDepositArgs({
  required String queueId,
  required List<int> depositCap,
  List<int>? sealed,
}) {
  if (!mailboxCapStringIsSafe(queueId)) {
    throw StateError('unsafe mailbox queue');
  }
  if (depositCap.length != kMailboxCapBytes) {
    throw StateError('invalid deposit capability');
  }
  if (sealed != null && sealed.isEmpty) {
    throw StateError('empty mailbox envelope');
  }
}

void _assertReadArgs({
  required String queueId,
  required List<int> readCap,
}) {
  if (!mailboxCapStringIsSafe(queueId)) {
    throw StateError('unsafe mailbox queue');
  }
  if (readCap.length != kMailboxCapBytes) {
    throw StateError('invalid read capability');
  }
}

class MailboxPump {
  EncryptedBlock deposit({
    required BlindMailboxStore store,
    required String queueId,
    required List<int> depositCap,
    required List<int> sealedEnvelope,
  }) {
    _assertDepositArgs(
      queueId: queueId,
      depositCap: depositCap,
      sealed: sealedEnvelope,
    );
    return store.put(
      queueId: queueId,
      depositCap: depositCap,
      bytes: Uint8List.fromList(sealedEnvelope),
      blockHash: sha256HexOf(sealedEnvelope),
    );
  }

  List<EncryptedBlock> collect({
    required BlindMailboxStore store,
    required String queueId,
    required List<int> readCap,
    int fromSeq = 0,
  }) {
    _assertReadArgs(queueId: queueId, readCap: readCap);
    return store.get(queueId: queueId, readCap: readCap, fromSeq: fromSeq);
  }

  Future<EncryptedBlock> depositClient({
    required StoragePeerClient client,
    required String queueId,
    required List<int> depositCap,
    required List<int> sealedEnvelope,
  }) {
    _assertDepositArgs(
      queueId: queueId,
      depositCap: depositCap,
      sealed: sealedEnvelope,
    );
    return client.put(
      queueId: queueId,
      depositCap: depositCap,
      bytes: sealedEnvelope,
    );
  }

  Future<List<EncryptedBlock>> collectClient({
    required StoragePeerClient client,
    required String queueId,
    required List<int> readCap,
    int fromSeq = 0,
  }) {
    _assertReadArgs(queueId: queueId, readCap: readCap);
    return client.get(
      queueId: queueId,
      readCap: readCap,
      fromSeq: fromSeq,
    );
  }
}
