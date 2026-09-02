// Phase 0 layer lock. See docs/migration/ADR-0001-layer-separation.md.
//
// These constants exist so a later Hyperswarm / Hypercore change cannot
// silently collapse identity, transport, replication, mailbox, and Drift
// into one "key" or one store. They are not a runtime switch.

/// Highest completed Holepunch migration phase. 0 = ADRs and contracts only.
const int kCompletedMigrationPhase = 0;

/// Application-layer room E2E is still false. Do not "upgrade" this flag
/// from the transport plugin. Source of truth remains
/// `kRoomsApplicationE2eImplemented` in `room_disclaimer.dart`.
const String kIdentityLayer = 'identity';
const String kTransportLayer = 'transport';
const String kReplicationLayer = 'replication';
const String kMailboxLayer = 'mailbox';
const String kDriftLayer = 'drift';

/// Fields that must never appear in a Hypercore / mailbox payload.
const Set<String> kForbiddenReplicationFields = <String>{
  'plaintext',
  'password',
  'kek',
  'vaultKek',
  'rootKey',
  'sendCk',
  'recvCk',
  'dhPriv',
  'skipped',
  'discoverySecret',
  'sharedDiscoverySecret',
  'attachmentBytes',
  'fileKey',
  'fileKeyB64',
  'privBytes',
};

/// Ordered connect-time checks. Block stays before decrypt/persist.
const List<String> kConnectBindingChecks = <String>[
  'noiseMatchesBinding',
  'signedByKnownIdentity',
  'deviceNotRevoked',
  'protocolCompatible',
  'contactNotBlocked',
  'tofuDoesNotConflict',
];

/// Returns false if [fields] contain a forbidden replication key.
bool replicationFieldsAreSafe(Iterable<String> fields) {
  for (final name in fields) {
    if (kForbiddenReplicationFields.contains(name)) return false;
  }
  return true;
}
