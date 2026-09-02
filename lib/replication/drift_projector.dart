// Drift is the read-model. This projector applies journal events after
// a local decrypt hook. It never writes plaintext into the journal.

import 'memory_journal.dart';
import '../transport/replication_schema.dart';

typedef EnvelopeDecrypt = Future<Map<String, Object?>?> Function(
  List<int> encryptedEnvelope,
  String conversationId,
);

class ProjectedMessage {
  const ProjectedMessage({
    required this.eventId,
    required this.conversationId,
    required this.senderIdentity,
    required this.senderDeviceId,
    required this.plaintext,
    required this.status,
    this.createdAt = 0,
  });

  final String eventId;
  final String conversationId;
  final String senderIdentity;
  final String senderDeviceId;
  final String plaintext;
  final String status;
  final int createdAt;

  ProjectedMessage copyWith({String? status}) => ProjectedMessage(
        eventId: eventId,
        conversationId: conversationId,
        senderIdentity: senderIdentity,
        senderDeviceId: senderDeviceId,
        plaintext: plaintext,
        status: status ?? this.status,
        createdAt: createdAt,
      );
}

/// Metadata-only attachment row. Ciphertext stays in the journal envelope
/// and is never decrypted here or persisted as a chat message.
class ProjectedAttachment {
  const ProjectedAttachment({
    required this.eventId,
    required this.conversationId,
    required this.chunkCount,
    required this.totalBytes,
    this.expired = false,
  });

  final String eventId;
  final String conversationId;
  final int chunkCount;
  final int totalBytes;
  final bool expired;

  ProjectedAttachment copyWith({bool? expired}) => ProjectedAttachment(
        eventId: eventId,
        conversationId: conversationId,
        chunkCount: chunkCount,
        totalBytes: totalBytes,
        expired: expired ?? this.expired,
      );
}

/// Non-message journal kinds projected into the local read-model.
/// [fields] never include fileKey, plaintext, ratchet scalars, or ciphertext.
class ProjectedNonMessage {
  const ProjectedNonMessage({
    required this.kind,
    required this.fields,
  });

  final ReplicationEventKind kind;
  final Map<String, Object?> fields;
}

class JournalProjector {
  JournalProjector({
    required this.decrypt,
    this.isBlocked,
    this.persist,
    this.persistNonMessage,
  });

  final EnvelopeDecrypt decrypt;
  final bool Function(String conversationId)? isBlocked;
  final Future<void> Function(ProjectedMessage message)? persist;
  final Future<void> Function(ProjectedNonMessage event)? persistNonMessage;
  final Map<String, ProjectedMessage> messages = <String, ProjectedMessage>{};
  final Map<String, String> devices = <String, String>{};
  final Map<String, bool> blocked = <String, bool>{};
  final Map<String, ProjectedAttachment> attachments =
      <String, ProjectedAttachment>{};
  final Map<String, String> membership = <String, String>{};
  final Set<String> seenEventIds = <String>{};
  int cursor = 0;

  Future<void> applyAll(MemoryJournal journal) async {
    for (final record in journal.since(cursor)) {
      await apply(record);
      cursor = record.seq + 1;
    }
  }

  /// Stable identity of the read-model. Used to detect live vs replay drift.
  String fingerprint() {
    final keys = messages.keys.toList()..sort();
    final rows = <String>[
      for (final id in keys)
        '$id|${messages[id]!.status}|${messages[id]!.plaintext}|${messages[id]!.conversationId}',
    ];
    final deviceKeys = devices.keys.toList()..sort();
    final deviceRows = [
      for (final id in deviceKeys) 'd:$id:${devices[id]}',
    ];
    final blockedKeys = blocked.keys.toList()..sort();
    final blockedRows = [
      for (final id in blockedKeys) 'b:$id:${blocked[id]}',
    ];
    final attKeys = attachments.keys.toList()..sort();
    final attRows = [
      for (final id in attKeys)
        'a:$id:${attachments[id]!.conversationId}:${attachments[id]!.chunkCount}:${attachments[id]!.totalBytes}:${attachments[id]!.expired}',
    ];
    final memKeys = membership.keys.toList()..sort();
    final memRows = [
      for (final id in memKeys) 'm:$id:${membership[id]}',
    ];
    return '$cursor|${rows.join('\n')}|${deviceRows.join(';')}|${blockedRows.join(';')}|${attRows.join(';')}|${memRows.join(';')}';
  }

  bool matches(JournalProjector other) => fingerprint() == other.fingerprint();

  bool _conversationBlocked(String conv) {
    if (conv.isEmpty) return false;
    if (blocked[conv] == true) return true;
    return isBlocked?.call(conv) == true;
  }

  Future<void> _emitNonMessage(
    ReplicationEventKind kind,
    Map<String, Object?> fields,
  ) async {
    await persistNonMessage?.call(
      ProjectedNonMessage(kind: kind, fields: fields),
    );
  }

  String _membershipKey(String roomId, String peerId) =>
      roomId.isEmpty ? peerId : '$roomId\x1f$peerId';

  Future<void> apply(JournalRecord record) async {
    switch (record.kind) {
      case ReplicationEventKind.messageEnvelopeCreated:
        final id = record.fields['eventId'] as String?;
        if (id == null || seenEventIds.contains(id)) return;
        final conv = record.fields['conversationId'] as String? ?? '';
        if (_conversationBlocked(conv)) return;
        seenEventIds.add(id);
        final enc = record.fields['encryptedEnvelope'];
        if (enc is! List<int>) return;
        final plain = await decrypt(enc, conv);
        if (plain == null) return;
        final msg = ProjectedMessage(
          eventId: id,
          conversationId: conv,
          senderIdentity: record.fields['senderIdentity'] as String? ?? '',
          senderDeviceId: record.fields['senderDeviceId'] as String? ?? '',
          plaintext: plain['text'] as String? ?? '',
          status: 'delivered',
          createdAt: (record.fields['createdAt'] as num?)?.toInt() ?? 0,
        );
        messages[id] = msg;
        await persist?.call(msg);
      case ReplicationEventKind.deliveryAcknowledged:
        final ackId = record.fields['eventId'] as String?;
        if (ackId == null) return;
        final acked = messages[ackId];
        if (acked != null) messages[ackId] = acked.copyWith(status: 'delivered');
      case ReplicationEventKind.readAcknowledged:
        final readId = record.fields['eventId'] as String?;
        if (readId == null) return;
        final read = messages[readId];
        if (read != null) messages[readId] = read.copyWith(status: 'read');
      case ReplicationEventKind.messageTombstoned:
        final id = record.fields['eventId'] as String?;
        if (id != null) messages.remove(id);
      case ReplicationEventKind.deviceAuthorized:
        final deviceId = record.fields['deviceId'] as String?;
        if (deviceId == null || deviceId.isEmpty) return;
        // Revoke is terminal. Journal has no transport keys — do not mint
        // an AuthorizedDevice from this event.
        if (devices[deviceId] == 'revoked') return;
        devices[deviceId] = 'authorized';
        await _emitNonMessage(
          ReplicationEventKind.deviceAuthorized,
          {'deviceId': deviceId},
        );
      case ReplicationEventKind.deviceRevoked:
        final deviceId = record.fields['deviceId'] as String?;
        if (deviceId == null || deviceId.isEmpty) return;
        devices[deviceId] = 'revoked';
        await _emitNonMessage(
          ReplicationEventKind.deviceRevoked,
          {'deviceId': deviceId},
        );
      case ReplicationEventKind.contactBlocked:
        final peerId = (record.fields['peerId'] as String?) ??
            (record.fields['conversationId'] as String?) ??
            '';
        if (peerId.isEmpty) return;
        final isNowBlocked = record.fields['blocked'] != false;
        blocked[peerId] = isNowBlocked;
        final conv = record.fields['conversationId'] as String?;
        if (conv != null && conv.isNotEmpty) blocked[conv] = isNowBlocked;
        await _emitNonMessage(
          ReplicationEventKind.contactBlocked,
          {
            'peerId': peerId,
            'conversationId': conv ?? peerId,
            'blocked': isNowBlocked,
          },
        );
      case ReplicationEventKind.attachmentPublished:
        final id = record.fields['eventId'] as String?;
        if (id == null || id.isEmpty) return;
        final conv = record.fields['conversationId'] as String? ?? '';
        if (_conversationBlocked(conv)) return;
        // Ciphertext in encryptedEnvelope is not a chat body. Never decrypt
        // it here and never persist those bytes as a Drift message.
        final att = ProjectedAttachment(
          eventId: id,
          conversationId: conv,
          chunkCount: (record.fields['chunkCount'] as num?)?.toInt() ?? 0,
          totalBytes: (record.fields['totalBytes'] as num?)?.toInt() ?? 0,
        );
        attachments[id] = att;
        await _emitNonMessage(
          ReplicationEventKind.attachmentPublished,
          {
            'eventId': id,
            'conversationId': conv,
            'chunkCount': att.chunkCount,
            'totalBytes': att.totalBytes,
          },
        );
      case ReplicationEventKind.attachmentExpired:
        final id = record.fields['eventId'] as String?;
        if (id == null || id.isEmpty) return;
        final existing = attachments[id];
        if (existing != null) {
          attachments[id] = existing.copyWith(expired: true);
        } else {
          attachments[id] = ProjectedAttachment(
            eventId: id,
            conversationId: record.fields['conversationId'] as String? ?? '',
            chunkCount: 0,
            totalBytes: 0,
            expired: true,
          );
        }
        await _emitNonMessage(
          ReplicationEventKind.attachmentExpired,
          {
            'eventId': id,
            if (record.fields['conversationId'] != null)
              'conversationId': record.fields['conversationId'],
          },
        );
      case ReplicationEventKind.roomMembershipChanged:
        final peerId = record.fields['peerId'] as String? ?? '';
        if (peerId.isEmpty) return;
        final roomId = record.fields['roomId'] as String? ?? '';
        final action = record.fields['action'] as String? ?? 'join';
        membership[_membershipKey(roomId, peerId)] = action;
        await _emitNonMessage(
          ReplicationEventKind.roomMembershipChanged,
          {
            if (roomId.isNotEmpty) 'roomId': roomId,
            'peerId': peerId,
            'action': action,
            if (record.fields['displayName'] != null)
              'displayName': record.fields['displayName'],
          },
        );
    }
  }
}

/// Replay the journal into a local read-model. Drift is the sink, not
/// the sync source of truth. Block list runs before decrypt.
Future<int> projectJournalToReadModel({
  required MemoryJournal journal,
  required EnvelopeDecrypt decrypt,
  required Future<void> Function(ProjectedMessage message) persist,
  Future<void> Function(ProjectedNonMessage event)? persistNonMessage,
  bool Function(String conversationId)? isBlocked,
}) async {
  final projector = JournalProjector(
    decrypt: decrypt,
    isBlocked: isBlocked,
    persist: persist,
    persistNonMessage: persistNonMessage,
  );
  await projector.applyAll(journal);
  return projector.messages.length;
}
