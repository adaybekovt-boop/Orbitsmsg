// Web-only timing guard for the onboarding "freeze". On web there are no
// isolates, so scrypt runs on the single UI thread; at N=2^16 that blocked the
// page for many seconds. `deriveScryptRecord` now defaults web to N=2^14
// (scryptWebN) while native keeps 2^16 in a background isolate.
//
// Runs ONLY under `flutter test --platform chrome` (DDC — the same compiler as
// the `flutter run` debug build), so the printed milliseconds reflect what a
// user actually feels. It prints both the new web default and the old 2^16 for
// a side-by-side, and asserts the web default is the lighter factor.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/scrypt_kdf.dart';

void main() {
  test('web default uses the lighter work factor (N=2^14)', () async {
    final sw = Stopwatch()..start();
    final rec = await deriveScryptRecord(
      username: 'bench_user',
      password: 'correct horse battery staple',
    );
    sw.stop();
    // ignore: avoid_print
    print('[bench] WEB default  N=${rec.n}  derive=${sw.elapsedMilliseconds} ms');
    expect(rec.n, scryptWebN, reason: 'web should derive at the 2^14 floor');
  });

  test('old N=2^16 for comparison (what used to freeze the page)', () async {
    final sw = Stopwatch()..start();
    final rec = await deriveScryptRecord(
      username: 'bench_user',
      password: 'correct horse battery staple',
      params: const ScryptParams(n: 65536),
    );
    sw.stop();
    // ignore: avoid_print
    print('[bench] OLD full     N=${rec.n}  derive=${sw.elapsedMilliseconds} ms');
    expect(rec.n, 65536);
  });
}
