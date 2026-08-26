enum DbHealthStatus { ok, missing, quarantined }

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

DbHealthResult? lastDatabaseHealthCheck;

/// Web persists through IndexedDB rather than a SQLite file, so the native
/// corruption check is not applicable.
Future<DbHealthResult> ensureDatabaseHealthy({
  String? directory,
  String name = 'orbits',
}) async {
  const result = DbHealthResult(
    status: DbHealthStatus.ok,
    detail: 'SQLite health check is not applicable on web',
  );
  lastDatabaseHealthCheck = result;
  return result;
}
