import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/authenticode.dart';
import 'package:orbits_flutter/core/authenticode_io.dart';

void main() {
  const policy = kDefaultAuthenticodePolicy;

  AuthenticodeResult valid({
    String subject = 'CN=Orbits, OU=Release, O=Orbits, C=US',
    String? thumbprint,
  }) =>
      AuthenticodeResult(
        AuthenticodeStatus.valid,
        subject: subject,
        thumbprint: thumbprint,
      );

  group('AuthenticodePolicy (U-1)', () {
    test('allows a trusted chain with the pinned Orbits subject', () {
      expect(policy.allows(valid()), isTrue);
    });

    test('rejects a trusted chain from another publisher', () {
      expect(
        policy.allows(valid(subject: 'CN=Contoso, O=Contoso, C=US')),
        isFalse,
      );
    });

    test('rejects unsigned / untrusted / hash mismatch even with our subject',
        () {
      const subject = 'CN=Orbits, O=Orbits, C=US';
      expect(
        policy.allows(const AuthenticodeResult(
          AuthenticodeStatus.notSigned,
          subject: subject,
        )),
        isFalse,
      );
      expect(
        policy.allows(const AuthenticodeResult(
          AuthenticodeStatus.notTrusted,
          subject: subject,
        )),
        isFalse,
      );
      expect(
        policy.allows(const AuthenticodeResult(
          AuthenticodeStatus.hashMismatch,
          subject: subject,
        )),
        isFalse,
      );
    });

    test('when thumbprints are pinned, subject alone is not enough', () {
      const pinned = AuthenticodePolicy(
        requiredSubjectNeedles: ['CN=Orbits', 'O=Orbits'],
        allowedThumbprints: ['AABBCCDDEEFF00112233445566778899AABBCCDD'],
      );
      expect(pinned.allows(valid()), isFalse);
      expect(
        pinned.allows(valid(
          thumbprint: 'aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd',
        )),
        isTrue,
      );
    });
  });

  group('parseAuthenticodeJson', () {
    test('reads Valid + subject + thumbprint', () {
      final r = parseAuthenticodeJson(
        '{"Status":"Valid","Subject":"CN=Orbits, O=Orbits","Thumbprint":"DEAD"}',
      );
      expect(r.status, AuthenticodeStatus.valid);
      expect(r.subject, 'CN=Orbits, O=Orbits');
      expect(r.thumbprint, 'DEAD');
    });

    test('maps NotSigned', () {
      final r = parseAuthenticodeJson(
        '{"Status":"NotSigned","Subject":"","Thumbprint":""}',
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
