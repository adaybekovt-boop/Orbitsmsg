// DOCS-CHECK, NOT A SECURITY TEST
// Round 2 A.3: moved out of test/security/. These asserts are source/docs
// greps (readAsStringSync + contains). They do not demonstrate an attack.

// Phase 1.2 Windows updater guards (U-1).
//
// These fail on origin/main / Phase 0: the installer launched any non-empty
// .exe, the downloader wrote the final path in place with no size cap or
// idle timeout, and there was no Authenticode publisher pin.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final repoRoot = Directory.current;

  File file(String rel) => File('${repoRoot.path}${Platform.pathSeparator}'
      '${rel.replaceAll('/', Platform.pathSeparator)}');

  String read(String rel) {
    final f = file(rel);
    expect(f.existsSync(), isTrue, reason: '$rel is missing');
    return f.readAsStringSync();
  }

  test('installer requires Authenticode + publisher pin before launch (U-1)', () {
    final installer = read('lib/core/update_installer_io.dart');
    expect(installer, contains('signatureUntrusted'));
    expect(installer, contains('_verifier.verify'));
    expect(installer, contains('_policy.allows'));
    expect(installer, contains('.sha256'));
    expect(read('lib/core/update_installer.dart'),
        contains('signatureUntrusted'));
  });

  test('downloader caps size, times out, and uses a .part rename', () {
    final dl = read('lib/core/update_downloader_io.dart');
    expect(dl, contains('.part'));
    expect(dl, contains('renameSync'));
    expect(dl, contains('maxBytes'));
    expect(dl, contains('idleTimeout'));
    expect(dl, contains('connectTimeout'));
    expect(dl, isNot(contains('.sha256')));
    expect(read('lib/core/update_downloader.dart'), contains('tooLarge'));
    expect(read('lib/core/update_downloader.dart'), contains('timeout'));
  });

  test('docs describe Authenticode pin, secrets, and fail-closed unsigned EXEs',
      () {
    final docs = read('docs/windows-signing.md');
    expect(docs, contains('U-1'));
    expect(docs, contains('Authenticode'));
    expect(docs, contains('CN=Orbits'));
    expect(docs, contains('signtool'));
    expect(docs.toLowerCase(), contains('fail-closed'));
    expect(read('SECURITY.md'), contains('docs/windows-signing.md'));
  });
}
