// dart:io Authenticode check via PowerShell Get-AuthenticodeSignature (U-1).
// Only used on a real Windows build. Tests inject AuthenticodeVerifier fakes
// and never call this.

import 'dart:convert';
import 'dart:io';

import 'authenticode.dart';

class PowershellAuthenticodeVerifier implements AuthenticodeVerifier {
  PowershellAuthenticodeVerifier({
    this.timeout = const Duration(seconds: 15),
    this.runner,
  });

  final Duration timeout;

  /// Injectable `Process.run` so the JSON parser can be tested off Windows.
  final Future<ProcessResult> Function(String exe, List<String> args)? runner;

  @override
  Future<AuthenticodeResult> verify(String path) async {
    try {
      final escaped = path.replaceAll("'", "''");
      final script = '''
\$s = Get-AuthenticodeSignature -LiteralPath '$escaped'
[pscustomobject]@{
  Status = [string]\$s.Status
  Subject = [string]\$s.SignerCertificate.Subject
  Thumbprint = [string]\$s.SignerCertificate.Thumbprint
} | ConvertTo-Json -Compress
''';
      final run = runner ??
          ((exe, args) => Process.run(exe, args, runInShell: false));
      final result = await run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]).timeout(timeout);

      if (result.exitCode != 0) {
        return AuthenticodeResult(
          AuthenticodeStatus.error,
          message: 'Get-AuthenticodeSignature exited ${result.exitCode}',
        );
      }
      return parseAuthenticodeJson('${result.stdout}');
    } catch (e) {
      return AuthenticodeResult(
        AuthenticodeStatus.error,
        message: '$e',
      );
    }
  }
}

AuthenticodeResult parseAuthenticodeJson(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return const AuthenticodeResult(
        AuthenticodeStatus.error,
        message: 'Authenticode JSON was not an object',
      );
    }
    final status = parseAuthenticodeStatus('${decoded['Status'] ?? ''}');
    final subject = decoded['Subject'] as String?;
    final thumbprint = decoded['Thumbprint'] as String?;
    return AuthenticodeResult(
      status,
      subject: (subject == null || subject.isEmpty) ? null : subject,
      thumbprint: (thumbprint == null || thumbprint.isEmpty) ? null : thumbprint,
    );
  } catch (e) {
    return AuthenticodeResult(
      AuthenticodeStatus.error,
      message: '$e',
    );
  }
}
