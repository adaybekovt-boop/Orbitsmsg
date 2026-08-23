// Native SQLCipher opener. See sqlcipher_status.dart — this is intentionally
// null, not a forgotten stub. Row/blob encryption is a different layer.
import 'package:drift/drift.dart';

import 'sqlcipher_status.dart';

QueryExecutor? openCipherExecutor() {
  if (!kSqlCipherFileEncryptionEnabled) return null;
  // Per-platform SQLCipher executor would be constructed here.
  return null;
}
