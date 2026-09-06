// Pre-trusted identity public keys. A binding signature is meaningless
// unless the identity key was established by a contact invite or the
// local owner — never by the binding itself.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../peer/helpers.dart';
import '../storage/wrapped_snapshot.dart';

class TrustedIdentity {
  const TrustedIdentity({
    required this.peerId,
    required this.identityPublicKey,
    required this.isSelf,
    this.tofuOnly = false,
  });

  final String peerId;
  final Uint8List identityPublicKey;

  /// Local owner identity. Required for own-device privileges.
  final bool isSelf;

  /// Observed / first-seen pin. Must never grant replication or admin.
  final bool tofuOnly;
}

class TrustedIdentityStore {
  TrustedIdentityStore({
    this.writeSnapshot,
    this.readSnapshot,
  });

  WrappedSnapshotWriter? writeSnapshot;
  WrappedSnapshotReader? readSnapshot;

  final Map<String, TrustedIdentity> _byPeer = <String, TrustedIdentity>{};

  void trust({
    required String peerId,
    required List<int> identityPublicKey,
    bool isSelf = false,
    bool tofuOnly = false,
  }) {
    final norm = normalizePeerId(peerId);
    if (norm.isEmpty || identityPublicKey.isEmpty) {
      throw ArgumentError('trusted identity requires peerId and public key');
    }
    _byPeer[norm] = TrustedIdentity(
      peerId: norm,
      identityPublicKey: Uint8List.fromList(identityPublicKey),
      isSelf: isSelf,
      tofuOnly: tofuOnly,
    );
    unawaited(persist());
  }

  void forget(String peerId) {
    _byPeer.remove(normalizePeerId(peerId));
    unawaited(persist());
  }

  void clear() => _byPeer.clear();

  Future<void> hydrate() async {
    final reader = readSnapshot ?? readTrustedIdentitiesSnapshot;
    try {
      final bytes = await reader();
      if (bytes == null || bytes.isEmpty) return;
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map) return;
      raw.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final row = Map<String, Object?>.from(value);
        final spki = row['identityPublicKey'] as String? ?? '';
        if (spki.isEmpty) return;
        _byPeer[normalizePeerId(key)] = TrustedIdentity(
          peerId: normalizePeerId(key),
          identityPublicKey: Uint8List.fromList(base64Decode(spki)),
          isSelf: row['isSelf'] == true,
          tofuOnly: row['tofuOnly'] == true,
        );
      });
    } catch (_) {}
  }

  Future<void> persist() async {
    try {
      final encoded = <String, Object?>{
        for (final e in _byPeer.entries)
          e.key: <String, Object?>{
            'identityPublicKey': base64Encode(e.value.identityPublicKey),
            'isSelf': e.value.isSelf,
            'tofuOnly': e.value.tofuOnly,
          },
      };
      final bytes = utf8.encode(jsonEncode(encoded));
      if (writeSnapshot != null) {
        await writeSnapshot!(bytes);
        return;
      }
      await writeTrustedIdentitiesSnapshot(bytes);
    } catch (_) {}
  }

  TrustedIdentity? lookup(String peerId) => _byPeer[normalizePeerId(peerId)];

  bool isTrustedIdentity(String peerId, List<int> identityPublicKey) {
    final known = lookup(peerId);
    if (known == null || known.tofuOnly) return false;
    return identityKeysEqual(known.identityPublicKey, identityPublicKey);
  }

  bool isSelf(String peerId) => lookup(peerId)?.isSelf == true;
}

bool identityKeysEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var mismatch = 0;
  for (var i = 0; i < a.length; i++) {
    mismatch |= a[i] ^ b[i];
  }
  return mismatch == 0;
}

final trustedIdentityStore = TrustedIdentityStore();
