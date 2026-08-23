// Phase 4: peek does not consume; used OPKs stay unusable.
// Key generation is not exercised here — package:cryptography ECDH is
// unimplemented on the Dart VM (see test/helpers/pointycastle_ecdh.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/core/prekey_store.dart';

void main() {
  setUp(() => setKeyStore(InMemoryKeyStore()));

  test('peekFreshOPK is null for missing or already-used ids', () async {
    expect(await peekFreshOPK('missing'), isNull);
    await keyStore().put('prekeys', {
      'id': 'opk-used',
      'kind': 'opk',
      'used': 1,
    });
    expect(await peekFreshOPK('opk-used'), isNull);
  });

  test('countFreshOPKs ignores used rows', () async {
    await keyStore().put('prekeys', {'id': 'a', 'kind': 'opk', 'used': 0});
    await keyStore().put('prekeys', {'id': 'b', 'kind': 'opk', 'used': 1});
    expect(await countFreshOPKs(), 1);
  });
}
