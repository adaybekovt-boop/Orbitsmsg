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
    final now = DateTime.now().millisecondsSinceEpoch;
    return (_cores[writerKey] ?? const <EncryptedBlock>[])
        .where((b) => b.seq >= fromSeq && now - b.storedAt <= cap.retentionMs)
        .toList(growable: false);
  }

  /// Crypto-erasure: drop ciphertext so it cannot be fetched again.
  void tombstone(String token, String writerKey, int seq) {
    final cap = _caps[token];
    if (cap == null) throw StateError('mailbox capability rejected');
    final list = _cores[writerKey];
    if (list == null) return;
    list.removeWhere((b) => b.seq == seq);
  }
}
