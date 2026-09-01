import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/transport_noise_seed.dart';

void main() {
  test('seed is 32 bytes and not used as the public placeholder', () {
    final store = TransportNoiseSeedStore(
      writeSnapshot: (_) async {},
      readSnapshot: () async => null,
    );
    final seed = store.getOrCreate();
    expect(seed, hasLength(32));
    expect(store.getOrCreate(), seed);
    final pk = derivedTransportPublicPlaceholder(seed);
    final writer = derivedHypercorePublicPlaceholder(seed);
    expect(pk, hasLength(32));
    expect(writer, hasLength(32));
    expect(pk, isNot(equals(Uint8List.fromList(seed))));
    expect(writer, isNot(equals(pk)));
    expect(writer, isNot(equals(Uint8List.fromList(seed))));
  });

  test('hydrate restores a vault-wrapped seed', () async {
    final stored = List<int>.generate(32, (i) => i + 1);
    final store = TransportNoiseSeedStore(
      writeSnapshot: (_) async {},
      readSnapshot: () async => Uint8List.fromList(stored),
    );
    await store.hydrate();
    expect(store.getOrCreate(), stored);
  });

  test('noise public hex is 32 bytes or null', () {
    expect(noisePublicKeyFromHex(null), isNull);
    expect(noisePublicKeyFromHex('aa'), isNull);
    expect(
      noisePublicKeyFromHex('00' * 32),
      Uint8List.fromList(List<int>.filled(32, 0)),
    );
  });
}
