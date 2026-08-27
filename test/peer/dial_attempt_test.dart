// R13 — a timed-out dial must not publish a late OFFER or leak the PC.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/dial_attempt.dart';

void main() {
  test('createOffer slower than dialTimeout does not publish and is disposed',
      () async {
    final attempt = DialAttempt(1);
    var published = false;
    var disposed = 0;
    final slow = Completer<String>();

    final run = runOwnedDial<String>(
      attempt: attempt,
      createOffer: () => slow.future,
      publishOffer: (_) => published = true,
      dispose: () => disposed++,
      timeout: const Duration(milliseconds: 30),
    );

    await expectLater(run, throwsA(isA<TimeoutException>()));
    expect(attempt.cancelled, isTrue);
    expect(published, isFalse);
    expect(disposed, 1);

    // Late completion of the inner operation — must stay unpublished.
    slow.complete('late-offer');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(published, isFalse);
    expect(attempt.published, isFalse);
  });

  test('successful offer still publishes when not cancelled', () async {
    final attempt = DialAttempt(2);
    var published = '';
    await runOwnedDial<String>(
      attempt: attempt,
      createOffer: () async => 'sdp',
      publishOffer: (o) => published = o,
      dispose: () {},
      timeout: const Duration(seconds: 1),
    );
    expect(published, 'sdp');
    expect(attempt.published, isTrue);
  });
}
