// R11 / K02 — Pages must use the live repo path and must not deploy
// from an ungated push to main.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final yml = File('.github/workflows/pages.yml').readAsStringSync();

  test('pages.yml does not hardcode the old /tkmessenger/ base-href', () {
    expect(yml, isNot(contains('--base-href /tkmessenger/')));
    expect(yml, contains('BASE_HREF'));
    expect(yml, contains('GITHUB_REPOSITORY'));
  });

  test('pages.yml is gated on Analyze & Test + Security, not a raw main push',
      () {
    expect(yml, contains('workflow_run'));
    expect(yml, contains('Build & Release'));
    expect(yml, contains('Security scans'));
    expect(
      yml.contains(RegExp(r'on:\s+push:\s+branches:\s+\[main\]')),
      isFalse,
    );
    expect(
      yml,
      contains('Confirm Build & Release succeeded on the same commit'),
      reason: 'workflow_dispatch must require a green Build & Release (R6-21)',
    );
    expect(yml, contains('github.event_name == \'workflow_dispatch\''));
  });

  test('docs describe the Settings branch-protection step', () {
    final doc = File('docs/ci-protection.md').readAsStringSync();
    expect(doc, contains('Protect `main`'));
    expect(doc, contains('Analyze & Test'));
    expect(doc, contains('Security scans'));
  });
}
