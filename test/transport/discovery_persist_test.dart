import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';

void main() {
  tearDown(clearVaultKek);

  test('discovery secrets persist and are never the peer id', () async {
    await setVaultKek(List<int>.generate(32, (i) => (i * 7 + 3) & 0xff));
    Uint8List? snapshot;
    final store = DiscoverySecretStore(
      writeSnapshot: (bytes) async {
        snapshot = Uint8List.fromList(bytes);
      },
      readSnapshot: () async => snapshot,
    );
    final secret = List<int>.generate(32, (i) => 11 + i);
    store.put('ORBIT-AAAAAAAAAAAAAAAA', secret);
    await store.persist();
    expect(snapshot, isNotNull);
    expect(secret, isNot(equals('ORBIT-AAAAAAAAAAAAAAAA'.codeUnits)));

    final again = DiscoverySecretStore(
      writeSnapshot: (bytes) async {
        snapshot = Uint8List.fromList(bytes);
      },
      readSnapshot: () async => snapshot,
    );
    await again.hydrate();
    expect(again.get('orbit-aaaaaaaaaaaaaaaa'), secret);
    final local = again.getOrCreateLocal();
    expect(local.length, 32);
    expect(local, isNot(equals(secret)));
  });
}
