// Record-level scrypt derive/verify round-trip. Unlike roundtrip_scrypt_test
// (which pins raw KDF vectors), this drives the public API — exercising the
// off-main-isolate dispatch added for audit L10 end to end.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/scrypt_kdf.dart';

void main() {
  // Low N keeps CI fast; deriveScryptRecord clamps N to >= 8192.
  const fast = ScryptParams(n: 8192);

  test('derive then verify succeeds for the right password (via Isolate.run)',
      () async {
    final rec = await deriveScryptRecord(
      username: 'alice',
      password: 'correct horse battery staple',
      params: fast,
    );
    expect(rec.dkBytes.length, greaterThanOrEqualTo(32));

    final stored = ScryptStoredRecord.fromJson(rec.toJson())!;
    final ok = await verifyScryptRecordEx(
      username: 'alice',
      password: 'correct horse battery staple',
      record: stored,
    );
    expect(ok.ok, isTrue);
    expect(ok.dkBytes, equals(rec.dkBytes));
  });

  test('verify rejects the wrong password', () async {
    final rec = await deriveScryptRecord(
      username: 'alice',
      password: 'right-password',
      params: fast,
    );
    final stored = ScryptStoredRecord.fromJson(rec.toJson())!;
    final bad = await verifyScryptRecordEx(
      username: 'alice',
      password: 'wrong-password',
      record: stored,
    );
    expect(bad.ok, isFalse);
    expect(bad.dkBytes, isNull);
  });
}
