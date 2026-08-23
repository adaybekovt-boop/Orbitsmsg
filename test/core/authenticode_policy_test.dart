// A.1 — behavioral Authenticode pin (not a source grep).
//
// Round-1 "pinned Authenticode" was a substring Subject check with an empty
// thumbprint list. A Valid chain whose CN merely *contains* "Orbits" was
// accepted. This file is the exploit + the required pin.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/authenticode.dart';
import 'package:orbits_flutter/core/update_installer.dart';
import 'package:orbits_flutter/core/update_installer_io.dart';

void main() {
  const lookalikeSubject = 'CN=Orbits Malware Inc, O=Orbits, C=US';
  const exactSubject = 'CN=Orbits, OU=Release, O=Orbits, C=US';
  const attackerThumb =
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

  group('default production policy (A.1 exploit)', () {
    test('rejects a Valid lookalike CN that only contains "Orbits"', () {
      final spoof = AuthenticodeResult(
        AuthenticodeStatus.valid,
        subject: lookalikeSubject,
        thumbprint: attackerThumb,
      );
      expect(
        kDefaultAuthenticodePolicy.allows(spoof),
        isFalse,
        reason: 'CN=Orbits Malware Inc must not satisfy a publisher pin',
      );
    });

    test('rejects exact CN=Orbits when no production thumbprint is pinned', () {
      final unsignedPin = AuthenticodeResult(
        AuthenticodeStatus.valid,
        subject: exactSubject,
        thumbprint: attackerThumb,
      );
      expect(
        kDefaultAuthenticodePolicy.allows(unsignedPin),
        isFalse,
        reason:
            'empty thumbprint list must fail closed, not accept any Orbits CN',
      );
      expect(
        kDefaultAuthenticodePolicy.allowedThumbprints,
        isEmpty,
        reason: 'no production cert is provisioned yet',
      );
    });
  });

  group('installer launch uses the same pin', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('orbits_a1_');
    });
    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('does not launch a Valid lookalike publisher', () async {
      final exe = File(
        '${tempDir.path}${Platform.pathSeparator}orbits-windows-x64.exe',
      )..writeAsStringSync('MZ-fake');
      final launched = <String>[];
      final installer = IoUpdateInstaller(
        isWindows: true,
        launcher: (path, _) async {
          launched.add(path);
          return true;
        },
        verifier: _Stub(
          AuthenticodeResult(
            AuthenticodeStatus.valid,
            subject: lookalikeSubject,
            thumbprint: attackerThumb,
          ),
        ),
      );

      final result = await installer.launch(exe.path);
      expect(result.status, InstallLaunchStatus.signatureUntrusted);
      expect(result.launched, isFalse);
      expect(launched, isEmpty);
    });
  });

  group('policy with a real SHA-256 pin', () {
    const pinnedThumb =
        'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
    const pinned = AuthenticodePolicy(
      requiredCn: 'Orbits',
      requiredO: 'Orbits',
      allowedThumbprints: [pinnedThumb],
    );

    test('rejects lookalike CN even when the thumbprint matches', () {
      expect(
        pinned.allows(
          AuthenticodeResult(
            AuthenticodeStatus.valid,
            subject: lookalikeSubject,
            thumbprint: pinnedThumb,
          ),
        ),
        isFalse,
      );
    });

    test('rejects exact CN with the wrong thumbprint', () {
      expect(
        pinned.allows(
          AuthenticodeResult(
            AuthenticodeStatus.valid,
            subject: exactSubject,
            thumbprint: attackerThumb,
          ),
        ),
        isFalse,
      );
    });

    test('accepts only exact CN+O and the pinned SHA-256 thumbprint', () {
      expect(
        pinned.allows(
          AuthenticodeResult(
            AuthenticodeStatus.valid,
            subject: exactSubject,
            thumbprint: pinnedThumb.toLowerCase(),
          ),
        ),
        isTrue,
      );
    });
  });
}

class _Stub implements AuthenticodeVerifier {
  _Stub(this.result);
  final AuthenticodeResult result;
  @override
  Future<AuthenticodeResult> verify(String path) async => result;
}
