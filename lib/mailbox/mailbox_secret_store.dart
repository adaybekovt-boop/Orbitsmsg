// Vault-wrapped mailbox root secret. Never derived from a peer id.

import 'dart:async';
import 'dart:typed_data';

import '../core/vault_kek.dart';
import '../storage/wrapped_snapshot.dart';
import 'mailbox_capability.dart';

const String kMailboxSecretPrefsKey = 'orbits.mailbox.root.v1';
const String kMailboxSecretId = 'self';

Future<void> writeMailboxSecretSnapshot(List<int> plaintext) =>
    writeWrappedPrefsSnapshot(kMailboxSecretPrefsKey, plaintext);

Future<Uint8List?> readMailboxSecretSnapshot() =>
    readWrappedPrefsSnapshot(kMailboxSecretPrefsKey);

class MailboxSecretStore {
  MailboxSecretStore({this.writeSnapshot, this.readSnapshot});

  WrappedSnapshotWriter? writeSnapshot;
  WrappedSnapshotReader? readSnapshot;

  List<int>? _root;

  List<int>? peek() => _root == null ? null : List<int>.from(_root!);

  List<int> getOrCreate() {
    final existing = _root;
    if (existing != null && existing.length == kMailboxSecretBytes) {
      return List<int>.from(existing);
    }
    final secret = generateMailboxRootSecret();
    _root = secret;
    unawaited(persist());
    return List<int>.from(secret);
  }

  void put(List<int> secret) {
    if (secret.length != kMailboxSecretBytes) {
      throw ArgumentError('mailbox root must be $kMailboxSecretBytes bytes');
    }
    _root = List<int>.from(secret);
    unawaited(persist());
  }

  void clearMemory() => _root = null;

  Future<void> hydrate() async {
    final reader = readSnapshot ?? readMailboxSecretSnapshot;
    try {
      final bytes = await reader();
      if (bytes == null || bytes.isEmpty) return;
      final loaded = decodeSecretMap(bytes);
      final value = loaded[kMailboxSecretId];
      if (value != null && value.length == kMailboxSecretBytes) {
        _root = List<int>.from(value);
      }
    } catch (_) {}
  }

  Future<void> persist() async {
    try {
      final root = _root;
      if (root == null) return;
      final bytes = encodeSecretMap(<String, List<int>>{
        kMailboxSecretId: root,
      });
      if (writeSnapshot != null) {
        await writeSnapshot!(bytes);
        return;
      }
      if (!hasVaultKek()) return;
      await writeMailboxSecretSnapshot(bytes);
    } catch (_) {}
  }

  Future<DerivedMailboxCaps> deriveOwn() => deriveMailboxCaps(getOrCreate());
}
