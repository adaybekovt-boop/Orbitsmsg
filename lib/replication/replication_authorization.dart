// Authorization for Hypercore replication frames.
// Conversation records stay on that conversation's authenticated peer.
// Device / block-list records stay on the owner's other devices.

import 'dart:convert';
import 'dart:typed_data';

import '../peer/helpers.dart';
import '../transport/replication_schema.dart';
import 'conversation_id.dart';
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
  if (RegExp(r'^[0-9a-f]{64}$').hasMatch(raw)) return raw;
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
  return peerIsConversationMember(
    conversationId: cid,
    selfPeerId: self,
    authenticatedPeerId: peer,
  );
}

bool frameMayAcceptFrom(
  ReplicationEventKind kind,
  Map<String, Object?> fields, {
  required String authenticatedPeerId,
  required String selfPeerId,
  required bool peerIsOwnDevice,
}) {
  return recordMayReplicateTo(
    JournalRecord(seq: 0, writerDeviceId: '', kind: kind, fields: fields),
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

/// Canonical bytes for identity-key signatures on own-account records.
/// Excludes `signature`. Field keys are sorted. Byte arrays become JSON
/// number lists so `Uint8List`, `List<int>`, and `jsonDecode` arrays
/// sign and verify to the same payload after a wire round-trip.
List<int> canonicalReplicationRecordBytes({
  required ReplicationEventKind kind,
  required String writerDeviceId,
  required Map<String, Object?> fields,
}) {
  final keys = fields.keys.where((k) => k != 'signature').toList()..sort();
  final body = <String, Object?>{};
  for (final key in keys) {
    body[key] = _canonicalReplicationField(fields[key]);
  }
  return utf8.encode(
    jsonEncode(<String, Object?>{
      'v': 1,
      'kind': kind.name,
      'writerDeviceId': writerDeviceId,
      'fields': body,
    }),
  );
}

Object? _canonicalReplicationField(Object? value) {
  if (value is Uint8List) {
    return value.toList(growable: false);
  }
  if (value is List) {
    return value.map(_canonicalReplicationField).toList(growable: false);
  }
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalReplicationField(value[key]),
    };
  }
  return value;
}

List<int>? decodeReplicationSignature(Object? value) {
  if (value is List<int>) return List<int>.from(value);
  if (value is! String || value.isEmpty) return null;
  try {
    return base64Decode(value);
  } catch (_) {
    return null;
  }
}
