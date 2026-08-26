// Startup database health check + corruption quarantine (audit Round 5 B.3).
//
// This native-only implementation runs before Drift opens the SQLite file.
// Web uses IndexedDB and is routed to db_health_stub.dart instead.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../core/error_reporter.dart';

enum DbHealthStatus { ok, missing, quarantined }

class DbHealthResult {
  const DbHealthResult({
    required this.status,
    this.quarantinePath,
    this.detail,
  });

  final DbHealthStatus status;

  /// Where the damaged file was moved to (status == quarantined).
  final String? quarantinePath;

  /// Why it was quarantined (exception text / quick_check output).
  final String? detail;
}

/// Result of the last [ensureDatabaseHealthy] call in this process. Surfaces
/// to diagnostics/UI without wiring a provider around it.
DbHealthResult? lastDatabaseHealthCheck;

/// Verify (and if needed quarantine) the SQLite database at
/// `[directory]/<name>.sqlite`. When [directory] is null it resolves to the
/// app documents directory — matching drift_flutter's default location for
/// `driftDatabase(name: ...)` files.
Future<DbHealthResult> ensureDatabaseHealthy({
  String? directory,
  String name = 'orbits',
}) async {
  final dir = directory ?? await _defaultDirectory();
  final dbFile = File(p.join(dir, '$name.sqlite'));
  if (!dbFile.existsSync()) {
    const r = DbHealthResult(status: DbHealthStatus.missing);
    lastDatabaseHealthCheck = r;
    return r;
  }

  String? problem;
  try {
    final sqlite = sqlite3.open(dbFile.path);
    try {
      final res = sqlite.select('PRAGMA quick_check;');
      final firstRow = res.isEmpty ? null : res.first.values.first?.toString();
      if (firstRow != 'ok') {
        problem = 'quick_check: ${firstRow ?? '<empty>'}';
      }
    } finally {
      sqlite.dispose();
    }
  } catch (e) {
    problem = 'open failed: $e';
  }

  if (problem == null) {
    const r = DbHealthResult(status: DbHealthStatus.ok);
    lastDatabaseHealthCheck = r;
    return r;
  }

  // Quarantine — rename, never delete.
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final quarantinePath = p.join(dir, '$name.corrupt-$stamp.sqlite');
  var moved = false;
  try {
    dbFile.renameSync(quarantinePath);
    moved = true;
  } catch (e) {
    // Rename can fail on a locked file (especially on Windows). Keep the
    // original bytes in place rather than turning a health check into data
    // loss; Drift will surface the underlying open error during startup.
    problem = '$problem; rename failed: $e';
  }

  reportError(
    StateError('Database file was corrupt and has been quarantined'),
    {
      'source': 'db_health',
      'file': dbFile.path,
      if (moved) 'quarantine': quarantinePath,
      'detail': problem,
    },
  );

  final r = DbHealthResult(
    status: DbHealthStatus.quarantined,
    quarantinePath: moved ? quarantinePath : null,
    detail: problem,
  );
  lastDatabaseHealthCheck = r;
  return r;
}

Future<String> _defaultDirectory() async {
  final docs = await getApplicationDocumentsDirectory();
  return docs.path;
}
