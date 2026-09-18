// Bind inbound replication to the authenticated peer. Payload fields
// are never an authorization source — only `norm` + DeviceBinding.

import 'dart:convert';
import 'dart:typed_data';

import '../peer/helpers.dart';
import 'replication_schema.dart';

/// 1:1 conversation events. `conversationId` must be the pair between
/// self and the authenticated peer, unless the sender is an own device.
const Set<ReplicationEventKind> kConversationScopedReplicationKinds = {
  ReplicationEventKind.messageEnvelopeCreated,
  ReplicationEventKind.deliveryAcknowledged,
  ReplicationEventKind.readAcknowledged,
  ReplicationEventKind.messageTombstoned,
  ReplicationEventKind.attachmentPublished,
  ReplicationEventKind.attachmentExpired,
};

/// Own-account control events. Foreign contacts must never apply these.
const Set<ReplicationEventKind> kOwnAccountReplicationKinds = {
  ReplicationEventKind.contactBlocked,
  ReplicationEventKind.deviceAuthorized,
  ReplicationEventKind.deviceRevoked,
};

/// Canonical bytes for identity-key signatures on own-account records.
/// Excludes `signature`. Field keys are sorted. [List<int>] leaves are
/// base64 so sign and verify see the same bytes after a wire round-trip.
List<int> canonicalReplicationRecordBytes({
  required ReplicationEventKind kind,
  required String writerDeviceId,
  required Map<String, Object?> fields,
}) {
  final keys = fields.keys.where((k) => k != 'signature').toList()..sort();
  final body = <String, Object?>{};
  for (final key in keys) {
    body[key] = _canonicalFieldValue(fields[key]);
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

Object? _canonicalFieldValue(Object? value) {
  if (value is Uint8List) return base64Encode(value);
  if (value is List<int> && value is! String) return base64Encode(value);
  if (value is List) {
    return value.map(_canonicalFieldValue).toList(growable: false);
  }
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalFieldValue(value[key]),
    };
  }
  return value;
}

/// True when [conversationId] is the 1:1 pair between [selfPeerId] and
/// [peerId]. Own-device callers skip this and accept any conversation.
bool conversationScopedToPeer({
  required String conversationId,
  required String peerId,
  required String selfPeerId,
}) {
  final conv = normalizePeerId(conversationId);
  if (conv.isEmpty || conv.contains('://')) return false;
  final remote = normalizePeerId(peerId);
  final self = normalizePeerId(selfPeerId);
  return conv == remote || conv == self;
}

bool identityPublicKeysEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var mismatch = 0;
  for (var i = 0; i < a.length; i++) {
    mismatch |= a[i] ^ b[i];
  }
  return mismatch == 0;
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
