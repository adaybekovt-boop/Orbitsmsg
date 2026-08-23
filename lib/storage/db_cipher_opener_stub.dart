// Web/default stub for the SQLCipher executor.
//
// SQLCipher is native-only — the wasm sqlite3 build Drift uses on web is not
// cipher-enabled. See sqlcipher_status.dart for the product decision on
// native builds (also off, Windows CMake clash).
import 'package:drift/drift.dart';

import 'sqlcipher_status.dart';

QueryExecutor? openCipherExecutor() =>
    kSqlCipherFileEncryptionEnabled ? null : null;
