# DOCS-CHECK, NOT A SECURITY TEST

Round 2 **A.3**. Files here used to live in `test/security/` and created
the impression that substring greps were attack coverage.

They still run in `flutter test`. They only check that documentation or
source still mentions a string. They do **not** close a vulnerability.

## Inventory (before / after A.3)

`test/security/` had **51** `test(` cases across 9 files.

| File | Tests | Kind | After A.3 |
| --- | ---: | --- | --- |
| `android_signing_test.dart` | 10 | mixed: keytool/script runs + gradle greps | stays in `test/security/` |
| `repo_hygiene_test.dart` | 16 | repo/docs/CI SHA greps | `docs_consistency/` |
| `phase4_integrity_test.dart` | 7 | source greps | `docs_consistency/` |
| `privacy_docs_test.dart` | 4 | docs/pubspec greps | `docs_consistency/` |
| `network_hardening_test.dart` | 4 | source greps | `docs_consistency/` |
| `windows_updater_test.dart` | 3 | source greps (real pin tests: `test/core/authenticode_*`) | `docs_consistency/` |
| `room_disclaimer_test.dart` | 3 | file-absence + greps (real ack: `test/ui/create_join_room_sheet_test.dart`) | `docs_consistency/` |
| `fail_closed_storage_test.dart` | 2 | source greps | `docs_consistency/` |
| `ratchet_commit_test.dart` | 2 | source greps (behavior: `test/core` ratchet tests) | `docs_consistency/` |

**After:** `test/security/` keeps **1 file / 10 tests** (Android signing scripts).
**Moved:** **8 files / 41 tests** labeled docs-check.

Grep is still useful to stop a deprecated API string from returning. It is
not a proof that an attacker is rejected.
