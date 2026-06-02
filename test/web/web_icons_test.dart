// Smoke test for the web/PWA/Safari icon wiring. Guards against the classic
// "manifest/index references an icon file that doesn't exist" and "apple-touch
// icon missing" mistakes — exactly what breaks iOS Safari "Add to Home Screen".
//
// Runs against the committed web/ sources (flutter test cwd = package root).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final web = Directory('web');

  setUpAll(() {
    expect(web.existsSync(), isTrue, reason: 'run from the package root');
  });

  group('icon files exist', () {
    for (final rel in const [
      'web/favicon.png',
      'web/apple-touch-icon.png',
      'web/icons/Icon-192.png',
      'web/icons/Icon-512.png',
      'web/icons/Icon-maskable-192.png',
      'web/icons/Icon-maskable-512.png',
    ]) {
      test('$rel exists and is non-empty', () {
        final f = File(rel);
        expect(f.existsSync(), isTrue, reason: '$rel missing');
        expect(f.lengthSync(), greaterThan(0), reason: '$rel is empty');
      });
    }
  });

  group('index.html', () {
    late String html;
    setUpAll(() => html = File('web/index.html').readAsStringSync());

    test('references an apple-touch-icon', () {
      expect(html.contains('rel="apple-touch-icon"'), isTrue);
      expect(html.contains('apple-touch-icon.png'), isTrue);
    });

    test('declares Add-to-Home-Screen meta tags', () {
      expect(html.contains('apple-mobile-web-app-capable'), isTrue);
      expect(html.contains('mobile-web-app-capable'), isTrue);
      expect(html.contains('apple-mobile-web-app-title'), isTrue);
      expect(html.contains('theme-color'), isTrue);
    });

    test('links the manifest and favicon', () {
      expect(html.contains('rel="manifest"'), isTrue);
      expect(html.contains('favicon.png'), isTrue);
    });

    test('no leftover default Flutter app name', () {
      expect(html.contains('orbits_flutter'), isFalse,
          reason: 'default project name should be replaced with "Orbits"');
    });
  });

  group('manifest.json', () {
    late Map<String, Object?> manifest;
    setUpAll(() {
      manifest = jsonDecode(File('web/manifest.json').readAsStringSync())
          as Map<String, Object?>;
    });

    test('name/short_name are branded', () {
      expect(manifest['name'], 'Orbits');
      expect(manifest['short_name'], 'Orbits');
    });

    test('every icon src points at an existing file', () {
      final icons = (manifest['icons'] as List).cast<Map<String, Object?>>();
      expect(icons, isNotEmpty);
      for (final icon in icons) {
        final src = icon['src'] as String;
        final f = File('web/$src');
        expect(f.existsSync(), isTrue,
            reason: 'manifest icon "$src" does not exist in web/');
      }
    });

    test('has both any and maskable purposes', () {
      final icons = (manifest['icons'] as List).cast<Map<String, Object?>>();
      final purposes =
          icons.map((i) => (i['purpose'] as String?) ?? 'any').toSet();
      expect(purposes.contains('maskable'), isTrue);
      expect(purposes.contains('any'), isTrue);
    });

    test('theme/background colors are set (dark glass)', () {
      expect(manifest['background_color'], '#0A0E16');
      expect(manifest['theme_color'], '#0A0E16');
    });
  });
}
