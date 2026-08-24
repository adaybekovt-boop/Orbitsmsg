// Authenticode policy for the Windows auto-updater (U-1 / A.1).
//
// Round 1 claimed a "publisher pin" but used Subject.contains('CN=Orbits')
// with an empty thumbprint list. A Valid chain for
// `CN=Orbits Malware Inc, O=Orbits` was accepted.
//
// The pin is now:
//   1. Authenticode Status = Valid
//   2. Subject CN and O equal "Orbits" exactly (not a substring)
//   3. SHA-256 of the signer certificate DER is in [allowedThumbprints]
//
// [kOrbitsAuthenticodeSha256Thumbprints] is empty until a maintainer
// provisions a code-signing certificate. An empty list is fail-closed:
// the in-app updater will not launch any installer. See
// docs/windows-signing.md.

/// Windows `Get-AuthenticodeSignature` Status, plus a catch-all.
enum AuthenticodeStatus { valid, notSigned, notTrusted, hashMismatch, error }

class AuthenticodeResult {
  const AuthenticodeResult(
    this.status, {
    this.subject,
    this.thumbprint,
    this.message,
  });

  final AuthenticodeStatus status;
  final String? subject;

  /// SHA-256 of the signer certificate DER (hex). Not the Windows SHA-1
  /// "Thumbprint" property.
  final String? thumbprint;
  final String? message;

  bool get chainTrusted => status == AuthenticodeStatus.valid;
}

/// Publisher pin. [allowedThumbprints] is the SHA-256 list; empty means
/// reject every signature (no production cert provisioned).
class AuthenticodePolicy {
  const AuthenticodePolicy({
    required this.requiredCn,
    required this.requiredO,
    this.allowedThumbprints = const [],
  });

  final String requiredCn;
  final String requiredO;
  final List<String> allowedThumbprints;

  bool allows(AuthenticodeResult result) {
    if (!result.chainTrusted) return false;
    final subject = result.subject ?? '';
    if (subject.isEmpty) return false;
    final cn = dnAttribute(subject, 'CN');
    final o = dnAttribute(subject, 'O');
    if (cn == null || o == null) return false;
    if (!_asciiEqualsIgnoreCase(cn, requiredCn)) return false;
    if (!_asciiEqualsIgnoreCase(o, requiredO)) return false;

    if (allowedThumbprints.isEmpty) return false;
    final thumb = normalizeThumbprint(result.thumbprint);
    if (thumb.length != 64) return false;
    return allowedThumbprints
        .map(normalizeThumbprint)
        .where((t) => t.length == 64)
        .contains(thumb);
  }

  static String normalizeThumbprint(String? value) =>
      (value ?? '').replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
}

/// SHA-256 fingerprints of production Authenticode certificates.
/// Empty on purpose: no cert is purchased / in CI yet. Do not invent a
/// self-signed production pin. Empty = fail-closed AND in-app Install is
/// hidden (see [isAuthenticodePinProvisioned]).
const List<String> kOrbitsAuthenticodeSha256Thumbprints = <String>[];

/// True only when at least one SHA-256 (64 hex chars) is pinned.
bool isAuthenticodePinProvisioned([List<String>? thumbs]) {
  final list = thumbs ?? kOrbitsAuthenticodeSha256Thumbprints;
  return list
      .map(AuthenticodePolicy.normalizeThumbprint)
      .any((t) => t.length == 64);
}

/// Shown when the pin list is empty. Not [signatureUntrusted] — that
/// string implies a bad file, not "we have no cert yet".
const String kUpdateAutoUpdateUnavailableMessage =
    'Автообновление временно недоступно, скачайте вручную с GitHub Releases';

const String kLatestWindowsInstallerUrl =
    'https://github.com/adaybekovt-boop/tkmessenger/releases/latest/download/orbits-windows-x64.exe';

const AuthenticodePolicy kDefaultAuthenticodePolicy = AuthenticodePolicy(
  requiredCn: 'Orbits',
  requiredO: 'Orbits',
  allowedThumbprints: kOrbitsAuthenticodeSha256Thumbprints,
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

/// Exact Distinguished Name attribute (`CN`, `O`, …). Comma-separated,
/// optional double quotes. Not a substring search.
String? dnAttribute(String subject, String key) {
  final pattern = RegExp(
    '(?:^|,)\\s*${RegExp.escape(key)}\\s*=\\s*("(?:[^"]|\\\\")*"|[^,]+)',
    caseSensitive: false,
  );
  final match = pattern.firstMatch(subject);
  if (match == null) return null;
  var value = match.group(1)!.trim();
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    value = value.substring(1, value.length - 1);
  }
  return value;
}

bool _asciiEqualsIgnoreCase(String a, String b) =>
    a.toLowerCase() == b.toLowerCase();
