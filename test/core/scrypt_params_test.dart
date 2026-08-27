// R16 — scrypt r/p/dkLen/salt must be rejected before the KDF runs.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/base64_helpers.dart';
import 'package:orbits_flutter/core/scrypt_kdf.dart';

void main() {
  const goodSaltB64 = 'AQEBAQEBAQEBAQEBAQEBAQ=='; // 16 bytes

  ScryptStoredRecord rec({
    int n = scryptMinN,
    int r = scryptDefaultR,
    int p = scryptDefaultP,
    int dkLen = scryptDefaultDkLen,
    String? saltB64,
  }) =>
      ScryptStoredRecord(
        saltB64: saltB64 ?? goodSaltB64,
        n: n,
        r: r,
        p: p,
        dkLen: dkLen,
        verifierB64: 'x',
      );

  test('classifier rejects huge / negative / oversized params', () {
    expect(
      scryptParamsAdmissible(
        n: scryptMinN,
        r: scryptDefaultR,
        p: scryptDefaultP,
        dkLen: scryptDefaultDkLen,
        saltLen: 16,
      ),
      isTrue,
    );
    expect(
        scryptParamsAdmissible(
            n: scryptMinN, r: -1, p: 1, dkLen: 32, saltLen: 16),
        isFalse);
    expect(
        scryptParamsAdmissible(
            n: scryptMinN, r: 1 << 20, p: 1, dkLen: 32, saltLen: 16),
        isFalse);
    expect(
        scryptParamsAdmissible(
            n: scryptMinN, r: 8, p: -3, dkLen: 32, saltLen: 16),
        isFalse);
    expect(
        scryptParamsAdmissible(
            n: scryptMinN, r: 8, p: 1, dkLen: -8, saltLen: 16),
        isFalse);
    expect(
        scryptParamsAdmissible(
            n: scryptMinN, r: 8, p: 1, dkLen: 32, saltLen: 8),
        isFalse);
    expect(
        scryptParamsAdmissible(
            n: scryptMinN, r: 8, p: 1, dkLen: 32, saltLen: 4096),
        isFalse);
  });

  test('verify rejects bad r/p/dkLen/salt without running a long KDF',
      () async {
    final cases = <ScryptStoredRecord>[
      rec(r: -1),
      rec(r: 1 << 16),
      rec(p: 0),
      rec(p: 1024),
      rec(dkLen: -4),
      rec(dkLen: 1 << 20),
      rec(saltB64: bytesToBase64(Uint8List.fromList(List<int>.filled(8, 1)))),
      rec(saltB64: bytesToBase64(Uint8List.fromList(List<int>.filled(4096, 1)))),
    ];
    for (final stored in cases) {
      final sw = Stopwatch()..start();
      final got = await verifyScryptRecordEx(
        username: 'alice',
        password: 'right-password',
        record: stored,
      );
      sw.stop();
      expect(got.ok, isFalse, reason: 'r=${stored.r} p=${stored.p}');
      expect(got.dkBytes, isNull);
      expect(sw.elapsedMilliseconds, lessThan(200),
          reason: 'must reject before expensive scrypt');
    }
  });
}
