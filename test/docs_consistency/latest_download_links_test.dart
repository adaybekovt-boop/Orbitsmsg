// DOCS-CHECK, NOT A SECURITY TEST
// In-repo download URLs must use GitHub's /releases/latest/download/ alias
// so they cannot rot the way the landing page's v8.0.2 pins did.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('README download table uses latest/download, not a pinned tag', () {
    final readme = File('README.md').readAsStringSync();
    expect(
      readme,
      contains(
        'https://github.com/adaybekovt-boop/tkmessenger/releases/latest/download/orbits-windows-x64.exe',
      ),
    );
    expect(
      readme,
      contains(
        'https://github.com/adaybekovt-boop/tkmessenger/releases/latest/download/orbits-android-universal.apk',
      ),
    );
    expect(readme.contains('releases/download/v8.'), isFalse);
    expect(readme.contains('/download/v8.0.2/'), isFalse);
  });

  test('in-app unavailable updater uses the same latest Windows URL', () {
    final src = File('lib/core/authenticode.dart').readAsStringSync();
    expect(
      src,
      contains(
        'https://github.com/adaybekovt-boop/tkmessenger/releases/latest/download/orbits-windows-x64.exe',
      ),
    );
  });
}
