// Per-contact discovery secrets. Never derived from a public Peer ID.
// At rest the map is vault-wrapped. Locked vault keeps RAM only.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../core/vault_kek.dart';
import '../peer/helpers.dart';
import '../storage/wrapped_snapshot.dart';

const String kLocalDiscoverySecretId = 'self';

typedef WrappedSnapshotWriter = Future<void> Function(List<int> plaintext);
typedef WrappedSnapshotReader = Future<Uint8List?> Function();

class DiscoverySecretStore {
  DiscoverySecretStore({
    this.writeSnapshot,
    this.readSnapshot,
  });

  WrappedSnapshotWriter? writeSnapshot;
  WrappedSnapshotReader? readSnapshot;

  final Map<String, List<int>> _secrets = <String, List<int>>{};

  void put(String peerId, List<int> secret) {
    if (secret.isEmpty) {
      throw ArgumentError('discovery secret must not be empty');
    }
    _secrets[normalizePeerId(peerId)] = List<int>.from(secret);
    unawaited(persist());
  }

  List<int>? get(String peerId) => _secrets[normalizePeerId(peerId)];

  void remove(String peerId) {
    _secrets.remove(normalizePeerId(peerId));
    unawaited(persist());
  }

  void clearMemory() => _secrets.clear();

  /// Local advertise secret. Independent of the public Peer ID.
  List<int> getOrCreateLocal() {
    final existing = get(kLocalDiscoverySecretId);
    if (existing != null) return existing;
    final secret = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    put(kLocalDiscoverySecretId, secret);
    return secret;
  }

  Future<void> hydrate() async {
    final reader = readSnapshot ?? readDiscoverySecretsSnapshot;
    try {
      final bytes = await reader();
      if (bytes == null || bytes.isEmpty) return;
      final loaded = decodeSecretMap(bytes);
      loaded.forEach((key, value) {
        if (value.isEmpty) return;
        _secrets[normalizePeerId(key)] = List<int>.from(value);
      });
    } catch (_) {
      // Locked vault or corrupt snapshot — keep whatever is already in RAM.
    }
  }

  Future<void> persist() async {
    try {
      final bytes = encodeSecretMap(_secrets);
      if (writeSnapshot != null) {
        await writeSnapshot!(bytes);
        return;
      }
      if (!hasVaultKek()) return;
      await writeDiscoverySecretsSnapshot(bytes);
    } catch (_) {}
  }
}

final discoverySecretStore = DiscoverySecretStore();
