import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/authenticode.dart';
import 'package:orbits_flutter/core/authenticode_io.dart';

void main() {
  const policy = kDefaultAuthenticodePolicy;
  const pinnedThumb =
      'AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899';
  const pinned = AuthenticodePolicy(
    requiredCn: 'Orbits',
    requiredO: 'Orbits',
    allowedThumbprints: [pinnedThumb],
  );

  AuthenticodeResult valid({
    String subject = 'CN=Orbits, OU=Release, O=Orbits, C=US',
    String? thumbprint,
  }) => AuthenticodeResult(
    AuthenticodeStatus.valid,
    subject: subject,
    thumbprint: thumbprint,
  );

  group('AuthenticodePolicy (U-1 / A.1)', () {
    test('default pin is empty and fail-closed', () {
      expect(policy.allowedThumbprints, isEmpty);
      expect(policy.allows(valid(thumbprint: pinnedThumb)), isFalse);
    });

    test('rejects a trusted chain from another publisher', () {
      expect(
        pinned.allows(
          valid(
            subject: 'CN=Contoso, O=Contoso, C=US',
            thumbprint: pinnedThumb,
          ),
        ),
        isFalse,
      );
    });

    test(
      'rejects unsigned / untrusted / hash mismatch even with our subject',
      () {
        const subject = 'CN=Orbits, O=Orbits, C=US';
        expect(
          pinned.allows(
            const AuthenticodeResult(
              AuthenticodeStatus.notSigned,
              subject: subject,
              thumbprint: pinnedThumb,
            ),
          ),
          isFalse,
        );
        expect(
          pinned.allows(
            const AuthenticodeResult(
              AuthenticodeStatus.notTrusted,
              subject: subject,
              thumbprint: pinnedThumb,
            ),
          ),
          isFalse,
        );
        expect(
          pinned.allows(
            const AuthenticodeResult(
              AuthenticodeStatus.hashMismatch,
              subject: subject,
              thumbprint: pinnedThumb,
            ),
          ),
          isFalse,
        );
      },
    );

    test('when thumbprints are pinned, subject alone is not enough', () {
      expect(pinned.allows(valid()), isFalse);
      expect(
        pinned.allows(valid(thumbprint: pinnedThumb.toLowerCase())),
        isTrue,
      );
    });
  });

  group('parseAuthenticodeJson', () {
    test('reads Valid + subject + SHA-256 thumbprint', () {
      final r = parseAuthenticodeJson(
        '{"Status":"Valid","Subject":"CN=Orbits, O=Orbits",'
        '"Sha256Thumbprint":"DEAD"}',
      );
      expect(r.status, AuthenticodeStatus.valid);
      expect(r.subject, 'CN=Orbits, O=Orbits');
      expect(r.thumbprint, 'DEAD');
    });

    test('ignores Windows SHA-1 Thumbprint so it cannot satisfy the pin', () {
      final r = parseAuthenticodeJson(
        '{"Status":"Valid","Subject":"CN=Orbits, O=Orbits",'
        '"Thumbprint":"${'AA' * 32}"}',
      );
      expect(r.thumbprint, isNull);
    });

    test('maps NotSigned', () {
      final r = parseAuthenticodeJson(
        '{"Status":"NotSigned","Subject":"","Sha256Thumbprint":""}',
      );
      expect(r.status, AuthenticodeStatus.notSigned);
      expect(r.subject, isNull);
    });

    test('malformed JSON is an error (fail closed)', () {
      final r = parseAuthenticodeJson('not-json');
      expect(r.status, AuthenticodeStatus.error);
    });
  });
}
