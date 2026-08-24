// DOCS-CHECK, NOT A SECURITY TEST
// Guards the Gitleaks allowlist contract. Does not scan the git history.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String toml;
  late String securityYml;
  late String securityMd;

  setUpAll(() {
    toml = File('.gitleaks.toml').readAsStringSync();
    securityYml = File('.github/workflows/security.yml').readAsStringSync();
    securityMd = File('docs/security.md').readAsStringSync();
  });

  test('gitleaks config extends the default ruleset', () {
    expect(toml, contains('useDefault = true'));
    expect(toml, isNot(contains('disabled = true')));
    expect(
      toml.contains(RegExp(r'id\s*=\s*"generic-api-key"')),
      isFalse,
      reason: 'redefining generic-api-key replaces the default rule',
    );
  });

  test('allowlist is limited to orbits identifiers and documented fixtures', () {
    expect(toml, contains(r'''^orbits[._][A-Za-z0-9._:-]+$'''));
    expect(toml, contains(r'''test/fixtures/crypto-fixtures\.json'''));
    expect(toml, contains('Local preference / vault key NAMES'));
  });

  test('security workflow still runs official gitleaks-action', () {
    expect(
      securityYml,
      contains(
        'gitleaks/gitleaks-action@ff98106e4c7b2bc287b24eaf42907196329070c7',
      ),
    );
    expect(securityYml, contains('.gitleaks.toml'));
  });

  test('security map records the allowlist (not a silent mute)', () {
    expect(securityMd, contains('.gitleaks.toml'));
    expect(securityMd, contains('generic-api-key'));
  });
}
