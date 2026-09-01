// Per-device Hyperswarm Noise seed. Distinct from identity-signing-v1,
// X3DH, Double Ratchet, discovery secrets, and vault KEK.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core/vault_kek.dart';
import '../storage/wrapped_snapshot.dart';

const String kTransportNoiseSeedPrefsKey = 'orbits.transport.noise.seed.v1';
const String kTransportNoisePkInfo = 'orbits-transport-noise-pk-v1';
const String kHypercoreWriterPkInfo = 'orbits-hypercore-writer-pk-v1';

class TransportNoiseSeedStore {
  TransportNoiseSeedStore({
    this.writeSnapshot,
    this.readSnapshot,
  });

  WrappedSnapshotWriter? writeSnapshot;
  WrappedSnapshotReader? readSnapshot;
  List<int>? _seed;

  List<int>? get current =>
      _seed == null ? null : List<int>.from(_seed!);

  List<int> getOrCreate() {
    final existing = current;
    if (existing != null) return existing;
    final seed = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    _seed = seed;
    unawaited(persist());
    return List<int>.from(seed);
  }

  Future<void> hydrate() async {
    final reader = readSnapshot ??
        (() => readWrappedPrefsSnapshot(kTransportNoiseSeedPrefsKey));
    try {
      final bytes = await reader();
      if (bytes == null || bytes.length != 32) return;
      _seed = List<int>.from(bytes);
    } catch (_) {}
  }

  Future<void> persist() async {
    final seed = _seed;
    if (seed == null || seed.length != 32) return;
    try {
      if (writeSnapshot != null) {
        await writeSnapshot!(seed);
        return;
      }
      if (!hasVaultKek()) return;
      await writeWrappedPrefsSnapshot(kTransportNoiseSeedPrefsKey, seed);
    } catch (_) {}
  }

  void clearMemory() => _seed = null;
}

final transportNoiseSeedStore = TransportNoiseSeedStore();

/// Stable 32-byte stand-in used when the worklet has not returned a real
/// Noise public key (loopback). Not the seed and not the identity key.
Uint8List derivedTransportPublicPlaceholder(List<int> seed) {
  return Uint8List.fromList(
    sha256.convert([...utf8.encode(kTransportNoisePkInfo), ...seed]).bytes,
  );
}

Uint8List derivedHypercorePublicPlaceholder(List<int> seed) {
  return Uint8List.fromList(
    sha256.convert([...utf8.encode(kHypercoreWriterPkInfo), ...seed]).bytes,
  );
}

Uint8List? noisePublicKeyFromHex(String? hex) {
  if (hex == null) return null;
  final s = hex.trim();
  if (s.length != 64) return null;
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    final byte = int.tryParse(s.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}
