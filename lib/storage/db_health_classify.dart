/// Shared DB-health types + classifiers (R15).
///
/// Quarantine (rename the file aside) is reserved for a *confirmed*
/// corrupt SQLite image. Busy / locked / read-only / permission / I/O
/// errors leave the file in place so a healthy DB is never moved.

enum DbHealthStatus { ok, missing, quarantined, unavailable }

class DbHealthResult {
  const DbHealthResult({
    required this.status,
    this.quarantinePath,
    this.detail,
  });

  final DbHealthStatus status;
  final String? quarantinePath;
  final String? detail;
}

/// Result of the last [ensureDatabaseHealthy] call in this process.
DbHealthResult? lastDatabaseHealthCheck;

/// True when [error] looks like a lock / permission / I/O problem rather
/// than a confirmed corrupt SQLite image.
bool isTransientDbHealthError(Object error) {
  final s = error.toString().toLowerCase();
  const needles = <String>[
    'database is locked',
    'database is busy',
    'sqlite_busy',
    'sqlite_locked',
    'error 5', // SQLITE_BUSY
    'error 6', // SQLITE_LOCKED
    'error 8', // SQLITE_READONLY
    'readonly',
    'read-only',
    'read only',
    'access denied',
    'permission denied',
    'operation not permitted',
    'errno = 11',
    'errno = 13',
    'errno = 16',
    'errno = 30',
    'errno = 1',
    'i/o error',
    'input/output error',
    'errno = 5',
  ];
  return needles.any(s.contains);
}

/// True when [quickCheck] failed or [error] reports a malformed image.
bool isConfirmedDbCorruption(Object? error, {String? quickCheck}) {
  if (quickCheck != null && quickCheck.isNotEmpty && quickCheck != 'ok') {
    return true;
  }
  if (error == null) return false;
  final s = error.toString().toLowerCase();
  return s.contains('not a database') ||
      s.contains('file is not a database') ||
      s.contains('database disk image is malformed') ||
      s.contains('file is encrypted or is not a database') ||
      (s.contains('corrupt') && !isTransientDbHealthError(error));
}
