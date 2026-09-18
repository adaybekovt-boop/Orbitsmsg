/// Blind mailbox: storage sees only [queueId], capability hashes, and opaque
/// sealed blocks. Sequence numbers are assigned here — never by the depositor.
library;

import 'dart:math';
import 'dart:typed_data';

import 'mailbox_capability.dart';

const int kMailboxMaxBlockBytes = 256 * 1024;
const int kMailboxDefaultQuotaBytes = 8 * 1024 * 1024;
const int kMailboxDefaultRetentionMs = 7 * 24 * 60 * 60 * 1000;

/// HTTP / IPC payload hard cap (body, not the queue quota).
const int kMailboxHttpMaxBodyBytes = 256 * 1024;

/// Soft back-pressure: drain before this many pending bytes.
const int kMailboxBacklogSoftBytes = 48 * 1024 * 1024;

/// Soft back-pressure: drain before this many pending blocks.
const int kMailboxBacklogSoftBlocks = 4096;

const int kMailboxRateWindowMs = 10 * 1000;
const int kMailboxRateMaxPuts = 32;

const int kMailboxBacklogRollbackBytes = kMailboxBacklogSoftBytes;
const int kMailboxBacklogRollbackCount = kMailboxBacklogSoftBlocks;
const int kMailboxHttpRateLimit = kMailboxRateMaxPuts;
const int kMailboxHttpRateWindowMs = kMailboxRateWindowMs;

class EncryptedBlock {
  EncryptedBlock({
    required this.seq,
    required List<int> bytes,
    int? createdAt,
    int? storedAt,
    String? blockHash,
  })  : bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        createdAt = createdAt ?? storedAt ?? 0,
        blockHash = blockHash ?? '';

  final int seq;
  final Uint8List bytes;
  final int createdAt;
  final String blockHash;

  int get storedAt => createdAt;
}

class MailboxQueue {
  MailboxQueue({
    required this.queueId,
    required this.readCapHash,
    required this.depositCapHash,
    required this.quotaBytes,
    required this.retentionMs,
    required this.expiresAt,
  });

  final String queueId;
  final String readCapHash;
  final String depositCapHash;
  final int quotaBytes;
  final int retentionMs;
  final int expiresAt;
  int nextSeq = 1;
  final List<EncryptedBlock> blocks = [];
  final Set<String> seenHashes = {};
}

class BlindMailboxStore {
  BlindMailboxStore({this.nowMs, this.requireAdminForFirstGrant = false});

  final int Function()? nowMs;
  final bool requireAdminForFirstGrant;

  final Map<String, MailboxQueue> _queues = {};
  final Map<String, List<int>> _queuePutTimes = {};
  final Map<String, List<int>> _depositCapPutTimes = {};

  int _now() => nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;

  MailboxQueue? _queue(String queueId) => _queues[queueId];

  void _assertNotExpired(MailboxQueue q) {
    if (q.expiresAt <= _now()) {
      throw StateError('mailbox expired');
    }
  }

  void _assertRead(MailboxQueue q, List<int> readCap) {
    _assertNotExpired(q);
    final hash = sha256HexOf(readCap);
    if (!constantTimeEqualsHex(hash, q.readCapHash)) {
      throw StateError('mailbox read capability rejected');
    }
  }

  void _assertDeposit(MailboxQueue q, List<int> depositCap) {
    _assertNotExpired(q);
    final hash = sha256HexOf(depositCap);
    if (!constantTimeEqualsHex(hash, q.depositCapHash)) {
      throw StateError('mailbox deposit capability rejected');
    }
  }

  /// Owner-register [queueId]. First registration may require [adminOk].
  /// Re-registration requires the current [readCap].
  MailboxCapability grant({
    required String queueId,
    required String readCapHash,
    required String depositCapHash,
    int? quotaBytes,
    int? retentionMs,
    int? expiresAt,
    List<int>? readCap,
    bool adminOk = false,
  }) {
    if (queueId.isEmpty ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(queueId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(readCapHash) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(depositCapHash)) {
      throw ArgumentError('invalid grant fields');
    }
    final now = _now();
    final existing = _queues[queueId];
    if (existing != null) {
      if (readCap == null || readCap.length != 32) {
        throw StateError('mailbox re-registration requires readCap');
      }
      _assertRead(existing, readCap);
    } else if (requireAdminForFirstGrant && !adminOk) {
      throw StateError('mailbox first registration requires admin');
    }
    final ttl = expiresAt ?? (now + kMailboxDefaultRetentionMs);
    if (ttl <= now || ttl > now + kMailboxMaxTtlMs) {
      throw ArgumentError('expiresAt out of range');
    }
    final q = MailboxQueue(
      queueId: queueId,
      readCapHash: readCapHash,
      depositCapHash: depositCapHash,
      quotaBytes: quotaBytes ?? kMailboxDefaultQuotaBytes,
      retentionMs: retentionMs ?? kMailboxDefaultRetentionMs,
      expiresAt: ttl,
    );
    if (existing != null) {
      q.nextSeq = existing.nextSeq;
      q.blocks.addAll(existing.blocks);
      q.seenHashes.addAll(existing.seenHashes);
    }
    _queues[queueId] = q;
    return MailboxCapability(
      queueId: queueId,
      readCapHash: readCapHash,
      depositCapHash: depositCapHash,
      quotaBytes: q.quotaBytes,
      retentionMs: q.retentionMs,
      expiresAt: q.expiresAt,
    );
  }

  EncryptedBlock put({
    required String queueId,
    required List<int> depositCap,
    required List<int> bytes,
    required String blockHash,
  }) {
    final q = _queue(queueId);
    if (q == null) throw StateError('unknown mailbox queue');
    _assertDeposit(q, depositCap);
    if (bytes.length > kMailboxMaxBlockBytes) {
      throw StateError('mailbox block too large');
    }
    final computed = sha256HexOf(bytes);
    if (!constantTimeEqualsHex(computed, blockHash.toLowerCase())) {
      throw StateError('mailbox blockHash mismatch');
    }
    _gc(q);
    if (q.seenHashes.contains(blockHash.toLowerCase())) {
      throw StateError('mailbox replay rejected');
    }
    final used = q.blocks.fold<int>(0, (n, b) => n + b.bytes.length);
    if (used + bytes.length > q.quotaBytes) {
      throw StateError('mailbox quota exceeded');
    }
    final t = _now();
    _rateCheck(_queuePutTimes, queueId, t);
    _rateCheck(_depositCapPutTimes, sha256HexOf(depositCap), t);
    final block = EncryptedBlock(
      seq: q.nextSeq++,
      bytes: Uint8List.fromList(bytes),
      createdAt: t,
      blockHash: blockHash.toLowerCase(),
    );
    q.blocks.add(block);
    q.seenHashes.add(block.blockHash);
    return block;
  }

  List<EncryptedBlock> get({
    required String queueId,
    required List<int> readCap,
    int fromSeq = 0,
  }) {
    final q = _queue(queueId);
    if (q == null) throw StateError('unknown mailbox queue');
    _assertRead(q, readCap);
    _gc(q);
    return [
      for (final b in q.blocks)
        if (b.seq >= fromSeq) b,
    ];
  }

  bool tombstone({
    required String queueId,
    required List<int> readCap,
    required int seq,
  }) {
    final q = _queue(queueId);
    if (q == null) throw StateError('unknown mailbox queue');
    _assertRead(q, readCap);
    final before = q.blocks.length;
    q.blocks.removeWhere((b) => b.seq == seq);
    return q.blocks.length < before;
  }

  Map<String, Object?> stats({
    required String queueId,
    required List<int> readCap,
  }) {
    final q = _queue(queueId);
    if (q == null) throw StateError('unknown mailbox queue');
    _assertRead(q, readCap);
    _gc(q);
    return {
      'queueId': queueId,
      'blocks': q.blocks.length,
      'bytes': q.blocks.fold<int>(0, (n, b) => n + b.bytes.length),
      'quotaBytes': q.quotaBytes,
      'retentionMs': q.retentionMs,
      'expiresAt': q.expiresAt,
    };
  }

  int pendingBytes(String queueId) {
    final q = _queue(queueId);
    if (q == null) return 0;
    return q.blocks.fold<int>(0, (n, b) => n + b.bytes.length);
  }

  int pendingBlocks(String queueId) {
    return _queue(queueId)?.blocks.length ?? 0;
  }

  int usedBytes(String queueId) => pendingBytes(queueId);

  int pendingCount(String queueId) => pendingBlocks(queueId);

  bool isBacklogged(
    String queueId, {
    int maxBytes = kMailboxBacklogRollbackBytes,
    int maxCount = kMailboxBacklogRollbackCount,
  }) {
    return pendingBytes(queueId) >= maxBytes ||
        pendingBlocks(queueId) >= maxCount;
  }

  int sweepExpired(String queueId) {
    final q = _queue(queueId);
    if (q == null) return 0;
    final before = q.blocks.length;
    _gc(q);
    return before - q.blocks.length;
  }

  void _gc(MailboxQueue q) {
    final cutoff = _now() - q.retentionMs;
    q.blocks.removeWhere((b) {
      final stale = b.createdAt < cutoff;
      if (stale) q.seenHashes.remove(b.blockHash);
      return stale;
    });
  }

  void _rateCheck(Map<String, List<int>> buckets, String key, int now) {
    final list = buckets.putIfAbsent(key, () => <int>[]);
    list.removeWhere((t) => now - t > kMailboxRateWindowMs);
    if (list.length >= kMailboxRateMaxPuts) {
      throw StateError('mailbox rate limited');
    }
    list.add(now);
  }
}

final _hexRand = Random.secure();

String randomHex32() {
  final b = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    b[i] = _hexRand.nextInt(256);
  }
  return mailboxBytesToHex(b);
}
