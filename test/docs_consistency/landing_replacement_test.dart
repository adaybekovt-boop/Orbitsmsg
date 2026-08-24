import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('in-repo landing replacement is Orbits, not Titan, and uses latest/', () {
    final html = File('docs/landing-replacement/index.html').readAsStringSync();
    expect(html, contains('Orbits'));
    expect(html, isNot(contains('Titan')));
    expect(html.toLowerCase(), isNot(contains('open source')));
    expect(
      html,
      contains(
        'https://github.com/adaybekovt-boop/tkmessenger/releases/latest/download/orbits-windows-x64.exe',
      ),
    );
    expect(
      html,
      contains(
        'https://github.com/adaybekovt-boop/tkmessenger/releases/latest/download/orbits-android-universal.apk',
      ),
    );
    expect(html.contains('/download/v8.'), isFalse);
    expect(html, contains('PeerJS'));
    expect(html, contains('Создать сервер можно только с компьютера'));
  });

  test('landing-honesty.md records the live Cloudflare site is out of repo', () {
    final docs = File('docs/landing-honesty.md').readAsStringSync();
    expect(docs, contains('https://orbits-eeo.pages.dev/'));
    expect(docs, contains('2026-08-24'));
    expect(docs, contains('v9.0.6'));
    expect(docs, contains('v8.0.2'));
    expect(docs, contains('description is still `das`'));
    expect(docs, contains('not in this repository'));
  });
}
