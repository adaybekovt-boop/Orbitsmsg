// HTTP client for a blind storage peer. Ciphertext only.

import 'dart:typed_data';

import 'blind_store.dart';
import 'mailbox_protocol.dart';

class MailboxDepositResult {
  const MailboxDepositResult({required this.duplicate, required this.seq});
  final bool duplicate;
  final int seq;
}

class StoragePeerClient {
  StoragePeerClient({
    required this.putRemote,
    required this.getRemote,
    this.tombstoneRemote,
    this.depositRemote,
    this.drainRemote,
    this.ackRemote,
    this.deleteRemote,
  });

  final Future<void> Function({
    required String token,
    required String writerKey,
    required EncryptedBlock block,
  })
  putRemote;

  final Future<List<EncryptedBlock>> Function({
    required String token,
    required String writerKey,
    int fromSeq,
  })
  getRemote;

  final Future<void> Function(String token, String writerKey, int seq)?
  tombstoneRemote;

  final Future<MailboxDepositResult> Function(MailboxHttpRequest request)?
  depositRemote;
  final Future<List<EncryptedBlock>> Function(MailboxHttpRequest request)?
  drainRemote;
  final Future<void> Function(MailboxHttpRequest request)? ackRemote;
  final Future<void> Function(MailboxHttpRequest request)? deleteRemote;

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

  Future<MailboxDepositResult> deposit(MailboxHttpRequest request) async {
    final fn = depositRemote;
    if (fn == null) {
      throw StateError('storage peer does not support versioned deposit');
    }
    return fn(request);
  }

  Future<List<EncryptedBlock>> drain(MailboxHttpRequest request) async {
    final fn = drainRemote;
    if (fn == null) {
      throw StateError('storage peer does not support versioned drain');
    }
    return fn(request);
  }

  Future<void> ack(MailboxHttpRequest request) async {
    final fn = ackRemote;
    if (fn == null) return;
    await fn(request);
  }

  Future<void> delete(MailboxHttpRequest request) async {
    final fn = deleteRemote;
    if (fn == null) {
      throw StateError('storage peer does not support versioned delete');
    }
    await fn(request);
  }

  /// In-process peer used by tests and desktop mailbox mode.
  factory StoragePeerClient.local(
    BlindMailboxStore store, {
    List<int>? grantSecret,
    int Function()? nowMs,
  }) {
    final clock = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);
    MailboxHttpRequest authorize(MailboxHttpRequest request) {
      final secret = grantSecret;
      if (secret != null) {
        verifyMailboxRequest(request, grantSecret: secret, nowMs: clock());
      }
      if (!store.rememberRequest(request.requestId)) {
        throw MailboxProtocolException('replay', 'request was already seen');
      }
      return request;
    }

    return StoragePeerClient(
      putRemote: ({required token, required writerKey, required block}) async {
        store.put(token: token, writerKey: writerKey, block: block);
      },
      getRemote: ({required token, required writerKey, fromSeq = 0}) async {
        return store.get(token: token, writerKey: writerKey, fromSeq: fromSeq);
      },
      tombstoneRemote: (token, writerKey, seq) async {
        store.tombstone(token, writerKey, seq);
      },
      depositRemote: (request) async {
        authorize(request);
        final existed = store.hasEnvelope(
          request.effectiveMailboxId,
          request.envelopeId!,
        );
        final block = store.depositEnvelope(
          mailboxId: request.effectiveMailboxId,
          envelopeId: request.envelopeId!,
          bytes: request.ciphertext!,
          quotaBytes: request.capability.quotaBytes,
          retentionMs: request.capability.retentionMs,
        );
        await store.persist();
        return MailboxDepositResult(duplicate: existed, seq: block.seq);
      },
      drainRemote: (request) async {
        authorize(request);
        return store.drainMailbox(
          mailboxId: request.effectiveMailboxId,
          retentionMs: request.capability.retentionMs,
          fromSeq: request.fromSeq,
        );
      },
      ackRemote: (request) async {
        authorize(request);
        store.acknowledge(request.effectiveMailboxId, request.envelopeId!);
        await store.persist();
      },
      deleteRemote: (request) async {
        authorize(request);
        store.deleteEnvelope(request.effectiveMailboxId, request.envelopeId!);
        await store.persist();
      },
    );
  }
}

const Set<String> kStoragePeerForbiddenKeys = kMailboxForbiddenKeys;

bool storagePeerBodyIsSafe(Map<String, Object?> body) {
  if (!mailboxBodyKeysAreSafe(body.keys)) return false;
  if (body.containsKey('v') && body['v'] == kMailboxHttpVersion) {
    return body.containsKey('op') &&
        body.containsKey('requestId') &&
        body.containsKey('capability');
  }
  return body.containsKey('token') &&
      body.containsKey('writerKey') &&
      (body.containsKey('b64') || body.containsKey('seq'));
}

MailboxHttpRequest depositRequest({
  required SignedMailboxCapability capability,
  required String envelopeId,
  required List<int> ciphertext,
  required String requestId,
  int? issuedAt,
}) {
  return MailboxHttpRequest(
    op: MailboxOp.deposit,
    requestId: requestId,
    issuedAt: issuedAt ?? DateTime.now().millisecondsSinceEpoch,
    capability: capability,
    mailboxId: capability.mailboxId,
    envelopeId: envelopeId,
    ciphertext: Uint8List.fromList(ciphertext),
  );
}

MailboxHttpRequest drainRequest({
  required SignedMailboxCapability capability,
  required String requestId,
  int fromSeq = 0,
  int? issuedAt,
}) {
  return MailboxHttpRequest(
    op: MailboxOp.drain,
    requestId: requestId,
    issuedAt: issuedAt ?? DateTime.now().millisecondsSinceEpoch,
    capability: capability,
    mailboxId: capability.mailboxId,
    fromSeq: fromSeq,
  );
}

MailboxHttpRequest ackRequest({
  required SignedMailboxCapability capability,
  required String envelopeId,
  required String requestId,
  int? issuedAt,
}) {
  return MailboxHttpRequest(
    op: MailboxOp.ack,
    requestId: requestId,
    issuedAt: issuedAt ?? DateTime.now().millisecondsSinceEpoch,
    capability: capability,
    mailboxId: capability.mailboxId,
    envelopeId: envelopeId,
  );
}

MailboxHttpRequest deleteRequest({
  required SignedMailboxCapability capability,
  required String envelopeId,
  required String requestId,
  int? issuedAt,
}) {
  return MailboxHttpRequest(
    op: MailboxOp.delete,
    requestId: requestId,
    issuedAt: issuedAt ?? DateTime.now().millisecondsSinceEpoch,
    capability: capability,
    mailboxId: capability.mailboxId,
    envelopeId: envelopeId,
  );
}
