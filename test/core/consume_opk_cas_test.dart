// R08 — consumeOPK must be an atomic used=0→1 compare-and-set.
// Two concurrent handshakes reading the same unused OPK must not both win.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/core/prekey_store.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/core/vault_kek.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  installPointyCastleEcdh();

  setUp(() async {
    setKeyStore(InMemoryKeyStore());
    await setVaultKek(List<int>.generate(32, (i) => (i * 17 + 3) & 0xff));
  });

  tearDown(() {
    clearVaultKek();
    setKeyStore(InMemoryKeyStore());
  });

  test('two parallel consumeOPK() calls: exactly one winner', () async {
    const id = 'opk-cas-race';
    final pair = await const PointyCastleP256Ecdh().newKeyPair();
    final data = await pair.extract();
    await keyStore().put('prekeys', {
      'id': id,
      'kind': 'opk',
      'status': 'fresh',
      'used': 0,
      'privBytes': await wrapSecret(data.d),
      'privEnc': 1,
      'pubSpki': buildP256Spki(x: data.x, y: data.y),
      'createdAt': 1,
    });

    final results = await Future.wait([consumeOPK(id), consumeOPK(id)]);

    final winners = results.where((r) => r != null).toList();
    expect(
      winners,
      hasLength(1),
      reason: 'exactly one concurrent consumeOPK may obtain the private key',
    );
    expect(winners.single!.id, id);

    final third = await consumeOPK(id);
    expect(third, isNull, reason: 'a later consume must not revive the OPK');

    final row = await keyStore().get('prekeys', id);
    expect((row!['used'] as num).toInt(), 1);
  });
}
