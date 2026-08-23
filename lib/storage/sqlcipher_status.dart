// Round 2 D.2 — SQLCipher decision record (not a silent null).
//
// Full-file SQLCipher is **disabled**. This is a Critical leftover from
// Round 1. It is not the same as fail-closed blob writes (`OB1` / wrapSecret):
// those encrypt selected payloads; the SQLite file itself stays plaintext
// (table names, peer IDs, timestamps, filenames remain readable).
//
// Why not on:
//   `sqlcipher_flutter_libs` and `sqlite3_flutter_libs` both register a
//   CMake target named `sqlite3` on Windows. Enabling SQLCipher without a
//   per-platform opener split breaks the Windows desktop build.
//
// No GitHub issue existed for this on 2026-08-23. This file *is* the
// decision record until a maintainer opens one and links it here.
//
// Flip [kSqlCipherFileEncryptionEnabled] only after a Windows-safe
// integration exists and `openCipherExecutor()` returns a real executor.

/// Full-file SQLCipher. False until the Windows CMake clash is resolved.
const bool kSqlCipherFileEncryptionEnabled = false;
