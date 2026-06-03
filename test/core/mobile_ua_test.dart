// Unit tests for the pure-Dart phone detector shared by the embedded
// signaling server and (as a fallback) the index.html gate.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/mobile_ua.dart';

void main() {
  group('isMobilePhoneUserAgent — blocks phones', () {
    const phones = {
      'iPhone Safari':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
              'Mobile/15E148 Safari/604.1',
      'iPod':
          'Mozilla/5.0 (iPod touch; CPU iPhone OS 16_0 like Mac OS X) '
              'AppleWebKit/605.1.15 Mobile/15E148',
      'Android phone Chrome':
          'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      'Android phone Firefox':
          'Mozilla/5.0 (Android 12; Mobile; rv:121.0) Gecko/121.0 Firefox/121.0',
      'Windows Phone':
          'Mozilla/5.0 (Windows Phone 10.0; Android 6.0.1; Microsoft; '
              'Lumia 950) AppleWebKit/537.36 IEMobile/11.0',
      'BlackBerry':
          'Mozilla/5.0 (BlackBerry; U; BlackBerry 9900; en) AppleWebKit/534.11+',
    };
    phones.forEach((name, ua) {
      test('$name → blocked', () {
        expect(isMobilePhoneUserAgent(ua), isTrue);
      });
    });
  });

  group('isMobilePhoneUserAgent — allows everything else', () {
    const allowed = {
      'null': null,
      'empty': '',
      'desktop Chrome (Windows)':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'desktop Safari (macOS)':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
              'Safari/605.1.15',
      'desktop Firefox (Linux)':
          'Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 '
              'Firefox/121.0',
      // iPadOS reports a desktop "Macintosh" UA → allowed.
      'iPad (desktop UA)':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
              'Safari/605.1.15',
      // Android *tablet* Chrome omits the "Mobile" token → allowed.
      'Android tablet Chrome':
          'Mozilla/5.0 (Linux; Android 13; SM-X710) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      // Native app guests connect via dart:io and send a Dart UA.
      'Dart native client': 'Dart/3.6 (dart:io)',
    };
    allowed.forEach((name, ua) {
      test('$name → allowed', () {
        expect(isMobilePhoneUserAgent(ua), isFalse);
      });
    });
  });
}
