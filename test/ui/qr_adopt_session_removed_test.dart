// A.6 — the QR "adopt the session" UI is a mined feature while the flag
// is false. Variant 1: the page that pops to root after a token signature
// must be deleted, not hidden.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('QR adopt-session page is deleted', () {
    expect(
      File('lib/pages/qr_pairing_page.dart').existsSync(),
      isFalse,
      reason: 'hiding the page behind kQrDeviceLinkingEnabled left the '
          'popUntil(isFirst) adopt path live',
    );
  });

  test('no adopt-session or false-login success path remains in lib/', () {
    final hits = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      if (src.contains('adopt the session') ||
          src.contains('popUntil((r) => r.isFirst)') ||
          src.contains('Вход подтверждён')) {
        hits.add(entity.path);
      }
    }
    expect(hits, isEmpty, reason: 'dangerous QR login strings: $hits');
  });
}
