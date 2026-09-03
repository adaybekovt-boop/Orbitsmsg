// Authorization for Hypercore replication frames.
// Conversation records stay on that conversation's authenticated peer.
// Device / block-list records stay on the owner's other devices.

import '../peer/helpers.dart';
import '../transport/replication_schema.dart';
import 'memory_journal.dart';

/// Who may see a journal record on the replication channel.
enum ReplicationAudience {
  /// Only the contact whose normalized peer id equals [conversationId].
  conversationPeer,

  /// Only other devices of the same identity. Never a contact.
  ownerDevices,
}

/// Records that describe the owner's device set or block list.
bool isOwnerDeviceScopedKind(ReplicationEventKind kind) {
  switch (kind) {
    case ReplicationEventKind.deviceAuthorized:
    case ReplicationEventKind.deviceRevoked:
    case ReplicationEventKind.contactBlocked:
      return true;
    case ReplicationEventKind.messageEnvelopeCreated:
    case ReplicationEventKind.deliveryAcknowledged:
    case ReplicationEventKind.readAcknowledged:
    case ReplicationEventKind.messageTombstoned:
    case ReplicationEventKind.attachmentPublished:
    case ReplicationEventKind.attachmentExpired:
    case ReplicationEventKind.roomMembershipChanged:
      return false;
  }
}

ReplicationAudience audienceForKind(ReplicationEventKind kind) {
  return isOwnerDeviceScopedKind(kind)
      ? ReplicationAudience.ownerDevices
      : ReplicationAudience.conversationPeer;
}

String? normalizedConversationId(Map<String, Object?> fields) {
  final raw = fields['conversationId'];
  if (raw is! String || raw.isEmpty) return null;
  return normalizePeerId(raw);
}

String? normalizedOwnerPeerId(Map<String, Object?> fields) {
  final raw = fields['ownerPeerId'];
  if (raw is! String || raw.isEmpty) return null;
  return normalizePeerId(raw);
}

/// Outbound and inbound visibility. Unscoped conversation records are
/// owner-device only — they must never ride a contact connection.
bool recordMayReplicateTo(
  JournalRecord record, {
  required String authenticatedPeerId,
  required String selfPeerId,
  required bool peerIsOwnDevice,
}) {
  final peer = normalizePeerId(authenticatedPeerId);
  final self = normalizePeerId(selfPeerId);
  if (peer.isEmpty) return false;

  if (audienceForKind(record.kind) == ReplicationAudience.ownerDevices) {
    if (!peerIsOwnDevice) return false;
    final owner = normalizedOwnerPeerId(record.fields) ?? self;
    return owner == self;
  }

  final cid = normalizedConversationId(record.fields);
  if (cid == null) return peerIsOwnDevice;
  if (peerIsOwnDevice) return true;
  return cid == peer;
}

bool frameMayAcceptFrom(
  ReplicationEventKind kind,
  Map<String, Object?> fields, {
  required String authenticatedPeerId,
  required String selfPeerId,
  required bool peerIsOwnDevice,
}) {
  return recordMayReplicateTo(
    JournalRecord(
      seq: 0,
      writerDeviceId: '',
      kind: kind,
      fields: fields,
    ),
    authenticatedPeerId: authenticatedPeerId,
    selfPeerId: selfPeerId,
    peerIsOwnDevice: peerIsOwnDevice,
  );
}

String bindingFingerprint({
  required String deviceId,
  required List<int> signature,
  required int createdAt,
}) {
  final sig = signature.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${normalizePeerId(deviceId)}|$createdAt|$sig';
}
