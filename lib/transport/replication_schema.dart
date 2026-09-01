// Encrypted journal event kinds. Phase 7 writes these to Hypercore.
// Bodies stay in [encryptedEnvelope] — never plaintext.

import 'layers.dart';

const int kReplicationEventVersion = 1;
const String kReplicationEventInfo = 'orbits-repl-event-v1';

enum ReplicationEventKind {
  messageEnvelopeCreated,
  deliveryAcknowledged,
  readAcknowledged,
  messageTombstoned,
  contactBlocked,
  deviceAuthorized,
  deviceRevoked,
  attachmentPublished,
  attachmentExpired,
  roomMembershipChanged,
}

class MessageEnvelopeCreated {
  const MessageEnvelopeCreated({
    required this.eventId,
    required this.conversationId,
    required this.senderIdentity,
    required this.senderDeviceId,
    required this.logicalSequence,
    required this.createdAt,
    required this.encryptedEnvelope,
    this.attachmentReferences = const <String>[],
    this.previousEventReference,
    this.eventVersion = kReplicationEventVersion,
  });

  final int eventVersion;
  final String eventId;
  final String conversationId;
  final String senderIdentity;
  final String senderDeviceId;
  final int logicalSequence;
  final int createdAt;

  /// Already-encrypted wire envelope (today: ratchet `v2:…`).
  final List<int> encryptedEnvelope;
  final List<String> attachmentReferences;
  final String? previousEventReference;

  Map<String, Object?> toJournalFields() => <String, Object?>{
        'eventVersion': eventVersion,
        'eventId': eventId,
        'conversationId': conversationId,
        'senderIdentity': senderIdentity,
        'senderDeviceId': senderDeviceId,
        'logicalSequence': logicalSequence,
        'createdAt': createdAt,
        'encryptedEnvelope': encryptedEnvelope,
        'attachmentReferences': attachmentReferences,
        'previousEventReference': previousEventReference,
      };

  bool get isSafeForHypercore =>
      replicationFieldsAreSafe(toJournalFields().keys);
}
