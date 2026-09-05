// Blind mailbox. Stores encrypted Hypercore blocks only.
// The peer never receives message keys or plaintext.

import 'dart:convert';
import 'dart:io';

import 'mailbox_protocol.dart';

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
    this.envelopeId,
    this.acked = false,
    this.tombstoned = false,
  });

  final int seq;
  final List<int> bytes;
  final int storedAt;
  final String? envelopeId;
  final bool acked;
  final bool tombstoned;

  EncryptedBlock copyWith({bool? acked, bool? tombstoned, List<int>? bytes}) {
    return EncryptedBlock(
      seq: seq,
      bytes: bytes ?? this.bytes,
      storedAt: storedAt,
      envelopeId: envelopeId,
      acked: acked ?? this.acked,
      tombstoned: tombstoned ?? this.tombstoned,
    );
  }

  Map<String, Object?> toPersistedJson() => <String, Object?>{
    'seq': seq,
    'b64': base64Encode(bytes),
    'storedAt': storedAt,
    if (envelopeId != null) 'envelopeId': envelopeId,
    'acked': acked,
    'tombstoned': tombstoned,
  };

  static EncryptedBlock? fromPersistedJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, Object?>.from(raw);
    if (!mailboxBodyKeysAreSafe(json.keys)) return null;
    final seq = json['seq'];
    final b64 = json['b64'];
    if (seq is! int || b64 is! String) return null;
    try {
      return EncryptedBlock(
        seq: seq,
        bytes: base64Decode(b64),
        storedAt: json['storedAt'] is int ? json['storedAt'] as int : 0,
        envelopeId: json['envelopeId'] as String?,
        acked: json['acked'] == true,
        tombstoned: json['tombstoned'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

class BlindMailboxStore {
  BlindMailboxStore({
    this.maxAnonymous = false,
    this.persistFile,
    int Function()? nowMs,
  }) : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final bool maxAnonymous;
  final File? persistFile;
  final int Function() nowMs;
  final Map<String, MailboxCapability> _caps = <String, MailboxCapability>{};
  final Map<String, List<EncryptedBlock>> _cores =
      <String, List<EncryptedBlock>>{};
  final Map<String, int> _seq = <String, int>{};
  final Map<String, int> _seenRequests = <String, int>{};

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
    if (block.envelopeId != null) {
      final existing = list.indexWhere((b) => b.envelopeId == block.envelopeId);
      if (existing >= 0) {
        return;
      }
    }
    final used = list
        .where((b) => !b.tombstoned)
        .fold<int>(0, (n, b) => n + b.bytes.length);
    if (used + block.bytes.length > cap.quotaBytes) {
      throw StateError('mailbox quota exceeded');
    }
    _validateStoredBlock(block);
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
    final now = nowMs();
    return (_cores[writerKey] ?? const <EncryptedBlock>[])
        .where(
          (b) =>
              !b.tombstoned &&
              b.seq >= fromSeq &&
              now - b.storedAt <= cap.retentionMs,
        )
        .toList(growable: false);
  }

  /// Crypto-erasure: drop ciphertext so it cannot be fetched again.
  void tombstone(String token, String writerKey, int seq) {
    final cap = _caps[token];
    if (cap == null) throw StateError('mailbox capability rejected');
    final list = _cores[writerKey];
    if (list == null) return;
    for (var i = 0; i < list.length; i++) {
      if (list[i].seq == seq) {
        list[i] = list[i].copyWith(
          tombstoned: true,
          bytes: encodeMailboxTombstone(
            id: list[i].envelopeId ?? 'seq-$seq',
            deletedAt: nowMs(),
          ),
        );
      }
    }
  }

  bool rememberRequest(String requestId) {
    final now = nowMs();
    _seenRequests.removeWhere(
      (_, issuedAt) => now - issuedAt > kMailboxReplayTtlMs,
    );
    if (_seenRequests.containsKey(requestId)) return false;
    _seenRequests[requestId] = now;
    return true;
  }

  /// Protocol-aware deposit. Idempotent on [envelopeId].
  EncryptedBlock depositEnvelope({
    required String mailboxId,
    required String envelopeId,
    required List<int> bytes,
    required int quotaBytes,
    required int retentionMs,
  }) {
    if (isMailboxTombstone(bytes)) {
      throw MailboxProtocolException('malformed', 'tombstone is not an envelope');
    }
    rejectPlaintextEnvelope(bytes);
    final list = _cores.putIfAbsent(mailboxId, () => <EncryptedBlock>[]);
    for (final existing in list) {
      if (existing.envelopeId == envelopeId) {
        return existing;
      }
    }
    final live = list.where((b) => !b.tombstoned);
    final used = live.fold<int>(0, (n, b) => n + b.bytes.length);
    if (used + bytes.length > quotaBytes) {
      throw MailboxProtocolException('quota', 'mailbox quota exceeded');
    }
    final block = EncryptedBlock(
      seq: _seq.update(mailboxId, (v) => v + 1, ifAbsent: () => 0),
      bytes: List<int>.from(bytes),
      storedAt: nowMs(),
      envelopeId: envelopeId,
    );
    list.add(block);
    return block;
  }

  List<EncryptedBlock> drainMailbox({
    required String mailboxId,
    required int retentionMs,
    int fromSeq = 0,
  }) {
    final now = nowMs();
    return (_cores[mailboxId] ?? const <EncryptedBlock>[])
        .where(
          (b) =>
              !b.tombstoned &&
              !b.acked &&
              b.seq >= fromSeq &&
              now - b.storedAt <= retentionMs,
        )
        .toList(growable: false);
  }

  void acknowledge(String mailboxId, String envelopeId) {
    final list = _cores[mailboxId];
    if (list == null) return;
    for (var i = 0; i < list.length; i++) {
      if (list[i].envelopeId == envelopeId) {
        list[i] = list[i].copyWith(acked: true);
      }
    }
  }

  void deleteEnvelope(String mailboxId, String envelopeId) {
    final list = _cores[mailboxId];
    if (list == null) return;
    for (var i = 0; i < list.length; i++) {
      if (list[i].envelopeId == envelopeId) {
        list[i] = list[i].copyWith(
          tombstoned: true,
          bytes: encodeMailboxTombstone(
            id: envelopeId,
            deletedAt: nowMs(),
          ),
        );
      }
    }
  }

  bool hasEnvelope(String mailboxId, String envelopeId) {
    return (_cores[mailboxId] ?? const <EncryptedBlock>[]).any(
      (b) => b.envelopeId == envelopeId && !b.tombstoned,
    );
  }

  Future<void> persist() async {
    final file = persistFile;
    if (file == null) return;
    final payload = <String, Object?>{
      'v': kMailboxHttpVersion,
      'cores': {
        for (final entry in _cores.entries)
          entry.key: entry.value.map((b) => b.toPersistedJson()).toList(),
      },
      'seq': _seq,
      'requests': _seenRequests,
    };
    final dir = file.parent;
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(payload));
    await tmp.rename(file.path);
  }

  Future<void> hydrate() async {
    final file = persistFile;
    if (file == null || !file.existsSync()) return;
    late final Object raw;
    try {
      raw = jsonDecode(await file.readAsString());
    } catch (error) {
      throw FormatException('corrupt mailbox persist: $error');
    }
    if (raw is! Map) {
      throw const FormatException('corrupt mailbox persist: not an object');
    }
    if (!mailboxBodyKeysAreSafe(raw.keys)) {
      throw const FormatException('corrupt mailbox persist: forbidden keys');
    }
    final cores = raw['cores'];
    if (cores is Map) {
      cores.forEach((key, value) {
        if (key is! String || value is! List) {
          throw const FormatException('corrupt mailbox persist: cores');
        }
        final blocks = <EncryptedBlock>[];
        for (final item in value) {
          if (item is Map && !mailboxBodyKeysAreSafe(item.keys)) {
            throw const FormatException(
              'corrupt mailbox persist: forbidden record',
            );
          }
          final block = EncryptedBlock.fromPersistedJson(item);
          if (block == null) {
            throw const FormatException('corrupt mailbox persist: bad record');
          }
          _hydrateStoredBlock(block);
          blocks.add(block);
        }
        _cores[key] = blocks;
      });
    } else if (cores != null) {
      throw const FormatException('corrupt mailbox persist: cores type');
    }
    final seq = raw['seq'];
    if (seq is Map) {
      seq.forEach((key, value) {
        if (key is String && value is int) _seq[key] = value;
      });
    }
    final requests = raw['requests'];
    if (requests is Map) {
      requests.forEach((key, value) {
        if (key is String && value is int) _seenRequests[key] = value;
      });
    }
  }

  void _validateStoredBlock(EncryptedBlock block) {
    if (block.tombstoned || isMailboxTombstone(block.bytes)) {
      requireMailboxTombstone(block.bytes);
      return;
    }
    rejectPlaintextEnvelope(block.bytes);
  }

  void _hydrateStoredBlock(EncryptedBlock block) {
    if (block.tombstoned) {
      if (block.bytes.isEmpty) {
        // Legacy persist: empty tombstone body is accepted, never decrypted.
        return;
      }
      requireMailboxTombstone(block.bytes);
      return;
    }
    if (isMailboxTombstone(block.bytes)) {
      requireMailboxTombstone(block.bytes);
      return;
    }
    rejectPlaintextEnvelope(block.bytes);
  }
}
