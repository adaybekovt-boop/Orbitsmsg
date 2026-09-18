// Applies own-account device journal records (deviceAuthorized /
// deviceRevoked) to the local DeviceRegistry + DeviceRatchetSessions.
//
// Used both by the live inbound replication path (DualStackBridge) and by
// the restart replay path (JournalProjector), so a revoke issued on one
// own-device lands on the others. Idempotent: safe to apply twice.

import '../devices/device_ratchet_sessions.dart';
import '../devices/device_registry.dart';
import '../peer/helpers.dart';
import '../transport/replication_schema.dart';
import 'memory_journal.dart';
import 'replication_authorization.dart';

/// Apply a verified-or-local own-account device record.
/// Returns true if registry/ratchets changed.
bool applyOwnAccountDeviceRecord(
  JournalRecord record, {
  DeviceRegistry? devices,
  DeviceRatchetSessions? ratchets,
  required String selfPeerId,
  String localDeviceId = '',
}) {
  if (record.kind != ReplicationEventKind.deviceRevoked &&
      record.kind != ReplicationEventKind.deviceAuthorized) {
    return false;
  }
  final self = normalizePeerId(selfPeerId);
  final owner = normalizedOwnerPeerId(record.fields);
  if (self.isEmpty || owner == null || owner != self) return false;

  final targetId = record.fields['deviceId'] as String? ?? '';
  if (targetId.isEmpty) return false;

  // The writer must be an own-device of this account. Note: the target
  // may be a contact device revoked from our own log, so never require
  // target.ownerPeerId == self here.
  final writer = record.writerDeviceId;
  final writerDev = devices?.byId(writer);
  final writerIsOwn = writer == localDeviceId ||
      (writerDev != null &&
          normalizePeerId(writerDev.ownerPeerId) == self);
  if (!writerIsOwn) return false;

  if (record.kind == ReplicationEventKind.deviceRevoked) {
    devices?.revoke(targetId, ownerPeerId: owner);
    ratchets?.revoke(targetId);
    return true;
  }

  final existing = devices?.byId(targetId);
  if (existing?.status == DeviceStatus.revoked) return false;

  final transportKey = _b64List(record.fields['transportPublicKey']);
  final hypercoreKey = _b64List(record.fields['hypercorePublicKey']);
  if (transportKey.isEmpty || hypercoreKey.isEmpty) return false;

  devices?.authorize(
    AuthorizedDevice(
      deviceId: targetId,
      transportPublicKey: transportKey,
      hypercorePublicKey: hypercoreKey,
      name: record.fields['name'] as String? ?? targetId,
      kind: record.fields['kind'] as String? ?? 'linked',
      createdAt: (record.fields['createdAt'] as num?)?.toInt() ?? 0,
      status: DeviceStatus.active,
      ownerPeerId: owner,
      transportPeerId: record.fields['transportPeerId'] as String?,
    ),
  );
  return true;
}

List<int> _b64List(Object? raw) {
  if (raw is List<int>) return List<int>.from(raw);
  if (raw is String && raw.isNotEmpty) {
    try {
      return base64Decode(raw);
    } catch (_) {}
  }
  return const <int>[];
}
