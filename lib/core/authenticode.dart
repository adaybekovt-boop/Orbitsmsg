// Authenticode policy for the Windows auto-updater (U-1).
//
// A valid Authenticode chain is not enough: the signer Subject must match the
// pinned Orbits publisher, and (once a real cert is provisioned) the
// thumbprint list. "Any trusted certificate" would let a random signed
// installer replace the app. See docs/windows-signing.md.

/// Windows `Get-AuthenticodeSignature` Status, plus a catch-all.
enum AuthenticodeStatus {
  valid,
  notSigned,
  notTrusted,
  hashMismatch,
  error,
}

class AuthenticodeResult {
  const AuthenticodeResult(
    this.status, {
    this.subject,
    this.thumbprint,
    this.message,
  });

  final AuthenticodeStatus status;
  final String? subject;
  final String? thumbprint;
  final String? message;

  bool get chainTrusted => status == AuthenticodeStatus.valid;
}

/// Publisher pin. [requiredSubjectNeedles] must all appear in the certificate
/// Subject (case-insensitive). When [allowedThumbprints] is non-empty, the
/// SHA-1 thumbprint must also match one of them (hex, case-insensitive).
class AuthenticodePolicy {
  const AuthenticodePolicy({
    required this.requiredSubjectNeedles,
    this.allowedThumbprints = const [],
  });

  final List<String> requiredSubjectNeedles;
  final List<String> allowedThumbprints;

  bool allows(AuthenticodeResult result) {
    if (!result.chainTrusted) return false;
    final subject = result.subject ?? '';
    if (subject.isEmpty) return false;
    final lower = subject.toLowerCase();
    for (final needle in requiredSubjectNeedles) {
      if (!lower.contains(needle.toLowerCase())) return false;
    }
    if (allowedThumbprints.isEmpty) return true;
    final thumb = _normalizeThumbprint(result.thumbprint);
    if (thumb.isEmpty) return false;
    return allowedThumbprints
        .map(_normalizeThumbprint)
        .where((t) => t.isNotEmpty)
        .contains(thumb);
  }

  static String _normalizeThumbprint(String? value) =>
      (value ?? '').replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
}

/// Pinned publisher for Orbits installers. Until a purchased / Trusted Signing
/// certificate is provisioned, no GitHub Release EXE will match a trusted
/// chain + this subject, so in-app update refuses to launch (fail-closed).
const AuthenticodePolicy kDefaultAuthenticodePolicy = AuthenticodePolicy(
  requiredSubjectNeedles: ['CN=Orbits', 'O=Orbits'],
);

/// Verifies an Authenticode signature. Production uses PowerShell
/// `Get-AuthenticodeSignature`; tests inject a fake.
abstract class AuthenticodeVerifier {
  Future<AuthenticodeResult> verify(String path);
}

/// Used off Windows and whenever a real verifier is unavailable. Always fail
/// closed — never treat "could not check" as trusted.
class FailClosedAuthenticodeVerifier implements AuthenticodeVerifier {
  const FailClosedAuthenticodeVerifier();

  @override
  Future<AuthenticodeResult> verify(String path) async =>
      const AuthenticodeResult(
        AuthenticodeStatus.notSigned,
        message: 'Authenticode verifier is not available',
      );
}

AuthenticodeStatus parseAuthenticodeStatus(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'valid':
      return AuthenticodeStatus.valid;
    case 'notsigned':
      return AuthenticodeStatus.notSigned;
    case 'nottrusted':
    case 'unknownerror':
      return AuthenticodeStatus.notTrusted;
    case 'hashmismatch':
    case 'incompatible':
      return AuthenticodeStatus.hashMismatch;
    default:
      return AuthenticodeStatus.error;
  }
}
