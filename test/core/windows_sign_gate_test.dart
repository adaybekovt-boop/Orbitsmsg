// A.1 — tag builds must not skip Authenticode signing.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, String> env(Map<String, String> extra) {
    final out = Map<String, String>.from(Platform.environment);
    out.remove('WINDOWS_CERT_PFX_BASE64');
    out.remove('WINDOWS_CERT_PFX_PASSWORD');
    extra.forEach((k, v) {
      if (v.isEmpty) {
        out.remove(k);
      } else {
        out[k] = v;
      }
    });
    return out;
  }

  ProcessResult run(Map<String, String> extra) {
    return Process.runSync('bash', [
      'tool/ci/sign_windows_exe.sh',
      'dist/orbits-windows-x64.exe',
    ], environment: env(extra));
  }

  test(
    'PR / branch without a PFX skips signing (updater will refuse the EXE)',
    () {
      final r = run({'GITHUB_REF': 'refs/heads/main'});
      expect(r.exitCode, 0, reason: '${r.stderr}\n${r.stdout}');
      expect('${r.stdout}${r.stderr}', contains('skip'));
    },
  );

  test('version tag without a PFX fails closed', () {
    final r = run({'GITHUB_REF': 'refs/tags/v9.0.7'});
    expect(r.exitCode, isNot(0));
    expect('${r.stderr}${r.stdout}', contains('WINDOWS_CERT_PFX_BASE64'));
  });
}
