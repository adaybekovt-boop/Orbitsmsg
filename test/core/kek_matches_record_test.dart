// Tests for `kekMatchesRecord` — the cheap (no-scrypt) check the "Remember me"
// auto-unlock path uses to validate a cached KEK against the stored record
// before installing it as the vault key.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/scrypt_kdf.dart';

void main() {
  const fast = ScryptParams(n: scryptMinN);

  test('accepts the genuine derived KEK (v2 verifier)', () async {
    final rec = await deriveScryptRecord(
      username: 'alice',
      password: 'correct horse battery staple',
      params: fast,
    );
    final stored = ScryptStoredRecord.fromJson(rec.toJson())!;
    expect(await kekMatchesRecord(rec.dkBytes, stored), isTrue);
  });

  test('rejects a wrong/corrupt KEK', () async {
    final rec = await deriveScryptRecord(
      username: 'alice',
      password: 'right-password',
      params: fast,
    );
    final stored = ScryptStoredRecord.fromJson(rec.toJson())!;
    final wrong = Uint8List(rec.dkBytes.length); // all-zero, not the real key
    expect(await kekMatchesRecord(wrong, stored), isFalse);
  });
}
