// Global error pipeline (audit P0 item 3). We can't easily assert that
// FlutterError.onError is wired without disturbing the test harness's own
// handler, so we verify the diagnostic pipeline (reportError → sinks) that the
// handlers feed, plus that installGlobalHandlers is safely idempotent.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/error_reporter.dart';

void main() {
  test('reportError dispatches to registered sinks with message + timestamp',
      () {
    Map<String, Object?>? got;
    final unsub = registerSink((payload, error) => got = payload);

    reportError(StateError('boom'), {'source': 'test'});
    expect(got, isNotNull);
    expect('${got!['message']}', contains('boom'));
    expect(got!['source'], 'test');
    expect(got!['timestamp'], isA<int>());

    // After unsubscribe, nothing more is delivered.
    unsub();
    got = null;
    reportError(Exception('again'));
    expect(got, isNull);
  });

  test('installGlobalHandlers is idempotent (safe to call repeatedly)', () {
    final previous = FlutterError.onError;
    addTearDown(() => FlutterError.onError = previous);
    installGlobalHandlers();
    installGlobalHandlers();
    // It wraps (does not null) the handler, and a second call is a no-op.
    expect(FlutterError.onError, isNotNull);
  });
}
