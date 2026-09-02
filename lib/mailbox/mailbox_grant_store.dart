// Per-contact mailbox deposit grants. Vault-wrapped. Never stores
// peerId as a queue address.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/vault_kek.dart';
import '../peer/helpers.dart';
import '../storage/wrapped_snapshot.dart';
import '../transport/layers.dart';
import 'mailbox_capability.dart';

const String kMailboxGrantPrefsKey = 'orbits.mailbox.grants.v1';

Future<void> writeMailboxGrantSnapshot(List<int> plaintext) =>
    writeWrappedPrefsSnapshot(kMailboxGrantPrefsKey, plaintext);

Future<Uint8List?> readMailboxGrantSnapshot() =>
    readWrappedPrefsSnapshot(kMailboxGrantPrefsKey);

class MailboxGrantStore {
  MailboxGrantStore({this.writeSnapshot, this.readSnapshot});

  WrappedSnapshotWriter? writeSnapshot;
  WrappedSnapshotReader? readSnapshot;

  final Map<String, MailboxGrant> _grants = <String, MailboxGrant>{};

  MailboxGrant? get(String peerId) => _grants[normalizePeerId(peerId)];

  void put(String peerId, MailboxGrant grant) {
    final norm = normalizePeerId(peerId);
    if (norm.isEmpty || norm.contains('://')) {
      throw ArgumentError('refusing mailbox grant peer');
    }
    if (!mailboxCapStringIsSafe(grant.queueId)) {
      throw ArgumentError('unsafe mailbox grant');
    }
    if (grant.storagePeerHint != null &&
        grant.storagePeerHint!.contains('://')) {
      throw ArgumentError('unsafe mailbox grant hint');
    }
    _grants[norm] = grant;
    unawaited(persist());
  }

  void remove(String peerId) {
    _grants.remove(normalizePeerId(peerId));
    unawaited(persist());
  }

  void clearMemory() => _grants.clear();

  Future<void> hydrate() async {
    final reader = readSnapshot ?? readMailboxGrantSnapshot;
    try {
      final bytes = await reader();
      if (bytes == null || bytes.isEmpty) return;
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map) return;
      raw.forEach((key, value) {
        if (key is! String || value is! Map) return;
        if (!replicationValueIsSafe(Map<String, Object?>.from(value))) return;
        final grant = MailboxGrant.fromWire(
          Map<String, Object?>.from(value)..['type'] = kMailboxGrantWireType,
        );
        if (grant == null) return;
        _grants[normalizePeerId(key)] = grant;
      });
    } catch (_) {}
  }

  Future<void> persist() async {
    try {
      final encoded = <String, Object?>{
        for (final e in _grants.entries)
          e.key: e.value.toWire()..remove('type'),
      };
      if (!replicationValueIsSafe(encoded)) return;
      final bytes = utf8.encode(jsonEncode(encoded));
      if (writeSnapshot != null) {
        await writeSnapshot!(bytes);
        return;
      }
      if (!hasVaultKek()) return;
      await writeMailboxGrantSnapshot(bytes);
    } catch (_) {}
  }
}
