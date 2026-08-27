// K01 — versioned unlock migration for legacy plaintext key-store rows.
//
// New writes are already OB1-sealed by [DriftKeyStore.put]. Rows written
// before that change stay plaintext until something touches them. This
// walk re-seals every leftover row as soon as the vault KEK is in RAM.

import '../core/key_store.dart';
import 'drift_key_store.dart';

/// Bump when the unlock walk gains another table or a new frame version.
const int kLegacySealMigrationVersion = 1;

/// Re-encrypt every legacy plaintext keys/prekeys/ratchets row. No-op for
/// the in-memory store. Safe to call repeatedly.
Future<int> migrateLegacySealedRows() async {
  final store = keyStore();
  if (store is DriftKeyStore) {
    return store.resealLegacyPlaintext();
  }
  return 0;
}
