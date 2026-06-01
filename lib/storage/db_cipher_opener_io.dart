// Native SQLCipher is intentionally disabled for release builds.
//
// The app still encrypts sensitive row payloads through the vault KEK layer in
// storage/db.dart. Full-file SQLCipher encryption needs a separate integration:
// sqlcipher_flutter_libs conflicts with sqlite3_flutter_libs on Windows because
// both register a CMake target named "sqlite3". Until the SQLite provider is
// wired per-platform without that duplicate target, fall back to Drift's normal
// native opener from database.dart.
import 'package:drift/drift.dart';

QueryExecutor? openCipherExecutor() => null;
