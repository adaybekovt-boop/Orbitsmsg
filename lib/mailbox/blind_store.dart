// Blind mailbox. Stores encrypted Hypercore blocks only.
// The peer never receives message keys or plaintext.

class MailboxCapability {
  const MailboxCapability({
    required this.token,
    required this.quotaBytes,
    required this.retentionMs,
    required this.expiresAt,
  });

  final String token;
  final int quotaBytes;
  final int retentionMs;
  final int expiresAt;

  bool get isExpired => DateTime.now().millisecondsSinceEpoch >= expiresAt;
}

class EncryptedBlock {
  const EncryptedBlock({
    required this.seq,
    required this.bytes,
    required this.storedAt,
  });

  final int seq;
  final List<int> bytes;
  final int storedAt;
}

/// Local operator threshold. Not a public-fleet SLA.
const int kMailboxBacklogRollbackBytes = 48 * 1024 * 1024;
const int kMailboxBacklogRollbackCount = 4096;

/// Amplification cap for one mailbox HTTP JSON body. Keep in sync with
/// `MAX_BODY_BYTES` in `tool/storage_peer/server.js`.
const int kMailboxHttpMaxBodyBytes = 256 * 1024;

/// Per-token deposit budget. Keep in sync with `RATE_LIMIT` /
/// `RATE_WINDOW_MS` in `tool/storage_peer/server.js`.
const int kMailboxHttpRateLimit = 32;
const int kMailboxHttpRateWindowMs = 10 * 1000;

class BlindMailboxStore {
  BlindMailboxStore({this.maxAnonymous = false});

  final bool maxAnonymous;
  final Map<String, MailboxCapability> _caps = <String, MailboxCapability>{};
  final Map<String, List<EncryptedBlock>> _cores =
      <String, List<EncryptedBlock>>{};

  void grant(MailboxCapability cap) {
    if (cap.token.isEmpty) {
      throw ArgumentError('anonymous writes are rejected');
    }
    _caps[cap.token] = cap;
  }

  void put({
    required String token,
    required String writerKey,
    required EncryptedBlock block,
  }) {
    final cap = _caps[token];
    if (cap == null || cap.isExpired) {
      throw StateError('mailbox capability rejected');
    }
    sweepExpired(token, writerKey);
    final list = _cores.putIfAbsent(writerKey, () => <EncryptedBlock>[]);
    final used = list.fold<int>(0, (n, b) => n + b.bytes.length);
    if (used + block.bytes.length > cap.quotaBytes) {
      throw StateError('mailbox quota exceeded');
    }
    list.add(block);
  }

  List<EncryptedBlock> get({
    required String token,
    required String writerKey,
    int fromSeq = 0,
  }) {
    final cap = _caps[token];
    if (cap == null || cap.isExpired) {
      throw StateError('mailbox capability rejected');
    }
    sweepExpired(token, writerKey);
    return (_cores[writerKey] ?? const <EncryptedBlock>[])
        .where((b) => b.seq >= fromSeq)
        .toList(growable: false);
  }

  /// Drop ciphertext whose retention window has elapsed. Returns the
  /// number of blocks removed. Called from get/put so GC is not only a
  /// filter on read.
  int sweepExpired(String token, String writerKey) {
    final cap = _caps[token];
    if (cap == null) return 0;
    final list = _cores[writerKey];
    if (list == null || list.isEmpty) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final before = list.length;
    list.removeWhere((b) => now - b.storedAt > cap.retentionMs);
    return before - list.length;
  }

  /// Crypto-erasure: drop ciphertext so it cannot be fetched again.
  void tombstone(String token, String writerKey, int seq) {
    final cap = _caps[token];
    if (cap == null) throw StateError('mailbox capability rejected');
    final list = _cores[writerKey];
    if (list == null) return;
    list.removeWhere((b) => b.seq == seq);
  }

  int usedBytes(String writerKey) =>
      (_cores[writerKey] ?? const <EncryptedBlock>[])
          .fold<int>(0, (n, b) => n + b.bytes.length);

  int pendingCount(String writerKey) =>
      (_cores[writerKey] ?? const <EncryptedBlock>[]).length;

  bool isBacklogged(
    String writerKey, {
    int maxBytes = kMailboxBacklogRollbackBytes,
    int maxCount = kMailboxBacklogRollbackCount,
  }) {
    return usedBytes(writerKey) >= maxBytes ||
        pendingCount(writerKey) >= maxCount;
  }
}
