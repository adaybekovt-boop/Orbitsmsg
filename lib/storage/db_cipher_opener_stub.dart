// Web/default stub for the SQLCipher executor.
//
// SQLCipher is native-only — the wasm sqlite3 build Drift uses on web is not
// cipher-enabled — so there's nothing to open here. Returns null; `_open`
// falls back to the plain (web/wasm) executor.
import 'package:drift/drift.dart';

QueryExecutor? openCipherExecutor() => null;
