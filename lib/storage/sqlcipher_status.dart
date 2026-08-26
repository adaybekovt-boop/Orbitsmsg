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
// Round 5 update: the residual risk was formally accepted in SECURITY.md
// ("Database encryption at rest"). Compensating controls now include
// storage-level sealing of keys/prekeys/ratchets (DriftKeyStore +
// saveRatchetState wrap every row under the vault KEK), so the crown-jewel
// tables no longer depend on caller discipline — only metadata columns
// remain plaintext until SQLCipher lands.
//
// Public write-up: `docs/security.md` § Known limitation: SQLCipher.

/// Headline mirrored in `docs/security.md`.
const String kSqlCipherKnownLimitationHeadline =
    'Known limitation: SQLCipher full-file encryption is off';

/// Full-file SQLCipher. False until the Windows CMake clash is resolved.
const bool kSqlCipherFileEncryptionEnabled = false;
