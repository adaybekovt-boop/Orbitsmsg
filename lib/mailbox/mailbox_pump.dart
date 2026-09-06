// Sender deposits encrypted envelopes; recipient fetches after the
// sender is gone. The store never receives keys or plaintext.

import 'blind_store.dart';
import 'mailbox_protocol.dart';
import 'storage_peer_client.dart';

class MailboxPump {
  int _seq = 0;
  int _requestNonce = 0;
  final Set<String> projectedEnvelopeIds = <String>{};

  String nextRequestId(String prefix) {
    _requestNonce += 1;
    return '$prefix-$_requestNonce';
  }

  void deposit({
    required BlindMailboxStore store,
    required String token,
    required String writerKey,
    required List<int> encryptedEnvelope,
    String? envelopeId,
  }) {
    store.put(
      token: token,
      writerKey: writerKey,
      block: EncryptedBlock(
        seq: _seq++,
        bytes: wrapOpaqueEnvelope(encryptedEnvelope),
        storedAt: DateTime.now().millisecondsSinceEpoch,
        envelopeId: envelopeId,
      ),
    );
  }

  List<EncryptedBlock> collect({
    required BlindMailboxStore store,
    required String token,
    required String writerKey,
    int fromSeq = 0,
  }) {
    return [
      for (final block in store.get(
        token: token,
        writerKey: writerKey,
        fromSeq: fromSeq,
      ))
        EncryptedBlock(
          seq: block.seq,
          bytes: requireOpaqueEnvelope(block.bytes),
          storedAt: block.storedAt,
          envelopeId: block.envelopeId,
          acked: block.acked,
          tombstoned: block.tombstoned,
        ),
    ];
  }

  Future<MailboxDepositResult> depositRemote({
    required StoragePeerClient client,
    required SignedMailboxCapability capability,
    required String envelopeId,
    required List<int> encryptedEnvelope,
  }) {
    return client.deposit(
      depositRequest(
        capability: capability,
        envelopeId: envelopeId,
        ciphertext: wrapOpaqueEnvelope(encryptedEnvelope),
        requestId: nextRequestId('dep'),
      ),
    );
  }

  Future<List<EncryptedBlock>> collectRemote({
    required StoragePeerClient client,
    required SignedMailboxCapability capability,
    int fromSeq = 0,
  }) async {
    final blocks = await client.drain(
      drainRequest(
        capability: capability,
        requestId: nextRequestId('drn'),
        fromSeq: fromSeq,
      ),
    );
    return [
      for (final block in blocks)
        EncryptedBlock(
          seq: block.seq,
          bytes: requireOpaqueEnvelope(block.bytes),
          storedAt: block.storedAt,
          envelopeId: block.envelopeId,
          acked: block.acked,
          tombstoned: block.tombstoned,
        ),
    ];
  }

  Future<void> acknowledgeRemote({
    required StoragePeerClient client,
    required SignedMailboxCapability capability,
    required String envelopeId,
  }) {
    return client.ack(
      ackRequest(
        capability: capability,
        envelopeId: envelopeId,
        requestId: nextRequestId('ack'),
      ),
    );
  }

  bool markProjected(String envelopeId) => projectedEnvelopeIds.add(envelopeId);
}
