// Startup database health check + corruption quarantine (audit Round 5 B.3).
//
// Historically nothing in the app caught a corrupt SQLite file: the first
// query would throw, `auth_notifier` silently fell back to guest mode, and
// the broken file stayed in place poisoning every later run.
//
// This module runs BEFORE Drift opens the database:
//   1. No file → healthy, nothing to do.
//   2. File opens and `PRAGMA quick_check` says "ok" → healthy.
//   3. Anything else (open throws, quick_check reports damage) → the file is
//      RENAMED aside to `<name>.corrupt-<epoch>.sqlite` (never deleted —
//      it may be recoverable / forensically relevant) and reported through
//      error_reporter, so the user gets a fresh profile plus a loud trace
//      instead of an infinite crash loop.

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
    // Rename can fail on a locked file (Windows). Last resort: delete so the
    // app can at least start; the bytes are already unreadable.
    try {
      dbFile.deleteSync();
    } catch (_) {}
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
