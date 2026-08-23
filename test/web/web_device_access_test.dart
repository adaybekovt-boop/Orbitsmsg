// Guards that the web app is NOT gated to desktop-only: phones must be able to
// open and use it. The phone-block (which rendered a "open from a computer" page
// before Flutter loaded) was removed; this test fails if it ever comes back.
//
// Runs against the committed web/index.html (flutter test cwd = package root).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String html;

  setUpAll(() {
    final f = File('web/index.html');
    expect(f.existsSync(), isTrue, reason: 'run from the package root');
    html = f.readAsStringSync();
  });

  test('the app bundle loads on every device (no pre-Flutter device gate)', () {
    // The loader must still be wired up…
    expect(html.contains('flutter_bootstrap.js'), isTrue);
    // …and must NOT short-circuit phones before it.
    expect(html.contains('isMobilePhone'), isFalse,
        reason: 'phone-detection gate is back in web/index.html');
    expect(html.contains('renderBlocked'), isFalse,
        reason: 'blocked-device screen is back in web/index.html');
    expect(html.contains('__orbitsAccessDenied'), isFalse,
        reason: 'the device-access verdict flag is back (gate reintroduced)');
  });

  test('no "phones are blocked" copy remains in index.html', () {
    expect(html.contains('Доступ с мобильных устройств запрещён'), isFalse);
    expect(html.contains('откройте'), isFalse,
        reason: 'the "open from a computer" block copy is back');
  });

  test('PWA manifest does not lock orientation (mobile web is allowed)', () {
    final raw = File('web/manifest.json').readAsStringSync();
    final json = jsonDecode(raw) as Map<String, Object?>;
    expect(json['orientation'], 'any');
  });
}
