// Official known limitation (Round 3 B.3) — not a silent leftover.
//
// Full-file SQLCipher is **disabled**. This is not the same as fail-closed
// blob writes (`OB1` / wrapSecret): those encrypt selected payloads; the
// SQLite file itself stays plaintext (table names, peer IDs, timestamps,
// filenames remain readable).
//
// Why not on:
//   `sqlcipher_flutter_libs` and `sqlite3_flutter_libs` both register a
//   CMake target named `sqlite3` on Windows. Enabling SQLCipher without a
//   per-platform opener split breaks the Windows desktop build.
//
// Next engineering step (no calendar date): split native openers so
// Windows can keep `sqlite3_flutter_libs` while Android/iOS/Linux use
// SQLCipher, then make `openCipherExecutor()` return a real executor.
// Flip [kSqlCipherFileEncryptionEnabled] only after that lands and CI
// builds Windows.
//
// Public write-up: `docs/security.md` § Known limitation: SQLCipher.

/// Headline mirrored in `docs/security.md`.
const String kSqlCipherKnownLimitationHeadline =
    'Known limitation: SQLCipher full-file encryption is off';

/// Full-file SQLCipher. False until the Windows CMake clash is resolved.
const bool kSqlCipherFileEncryptionEnabled = false;
