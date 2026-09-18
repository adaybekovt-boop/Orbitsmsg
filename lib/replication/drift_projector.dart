// Drift is the read-model. This projector applies journal events after
// a local decrypt hook. It never writes plaintext into the journal.

import 'device_journal_apply.dart';
import 'memory_journal.dart';
import '../devices/device_ratchet_sessions.dart';
import '../devices/device_registry.dart';
import '../transport/replication_schema.dart';

typedef EnvelopeDecrypt =
    Future<Map<String, Object?>?> Function(
      List<int> encryptedEnvelope,
      JournalRecord record,
    );

typedef ProjectedPersist = Future<void> Function(ProjectedMessage message);
typedef ProjectedTombstone = Future<void> Function(String eventId);

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

/// Drift is the read-model. Own outbound rows already exist from the composer.
Future<void> persistProjectedMessage(
  ProjectedMessage msg, {
  required String selfPeerId,
  required Future<bool> Function(Map<String, Object?> row) save,
}) async {
  final sender = msg.senderIdentity;
  if (sender.isEmpty) return;
  if (selfPeerId.isNotEmpty &&
      sender.toUpperCase() == selfPeerId.toUpperCase()) {
    return;
  }
  await save(<String, Object?>{
    'id': msg.eventId,
    'peerId': sender,
    'timestamp': msg.createdAt == 0
        ? DateTime.now().millisecondsSinceEpoch
        : msg.createdAt,
    'direction': 'in',
    'status': msg.status,
    'payload': <String, Object?>{
      'text': msg.plaintext,
      'from': sender,
    },
  });
}

class JournalProjector {
  JournalProjector({
    required this.decrypt,
    this.revokedWriters = const <String>{},
    this.maxEventVersion = kReplicationEventVersion,
    this.isBlocked,
    this.persist,
    this.tombstone,
    this.devices,
    this.ratchets,
    this.selfPeerId = '',
    this.localDeviceId = '',
    this.persistEnvelopePlaintext = false,
  });

  final EnvelopeDecrypt decrypt;
  final Set<String> revokedWriters;
  final int maxEventVersion;
  final bool Function(String peerId)? isBlocked;
  final ProjectedPersist? persist;
  final ProjectedTombstone? tombstone;
  final DeviceRegistry? devices;
  final DeviceRatchetSessions? ratchets;
  final String selfPeerId;
  final String localDeviceId;

  /// Live/host plaintext ingest. Default false: ciphertext journal rows
  /// stay off Drift and `onPacket` owns decrypt (clamps, receipts,
  /// sender keyed by the transport peer). Opt-in exists only for
  /// explicit replay tests — never for the live projector.
  final bool persistEnvelopePlaintext;
  final Map<String, ProjectedMessage> messages = <String, ProjectedMessage>{};
  final List<Map<String, Object?>> membershipChanges = <Map<String, Object?>>[];
  final Set<String> seenEventIds = <String>{};
  int cursor = 0;

  Future<void> applyAll(MemoryJournal journal) async {
    for (final record in journal.since(cursor)) {
      await apply(record);
      cursor = record.seq + 1;
    }
  }

  Future<void> applyInTransaction(Iterable<JournalRecord> records) async {
    final snapshot = Map<String, ProjectedMessage>.from(messages);
    final seen = Set<String>.from(seenEventIds);
    final membership = List<Map<String, Object?>>.from(membershipChanges);
    final savedCursor = cursor;
    try {
      for (final record in records) {
        await apply(record);
        cursor = record.seq + 1;
      }
    } catch (_) {
      messages
        ..clear()
        ..addAll(snapshot);
      seenEventIds
        ..clear()
        ..addAll(seen);
      membershipChanges
        ..clear()
        ..addAll(membership);
      cursor = savedCursor;
      rethrow;
    }
  }

  Future<void> apply(JournalRecord record) async {
    if (revokedWriters.contains(record.writerDeviceId)) return;
    final version = record.fields['eventVersion'];
    if (version is int && version > maxEventVersion) return;
    switch (record.kind) {
      case ReplicationEventKind.messageEnvelopeCreated:
        final id = record.fields['eventId'] as String?;
        if (id == null || seenEventIds.contains(id)) return;
        final sender = record.fields['senderIdentity'] as String? ?? '';
        if (sender.isNotEmpty && (isBlocked?.call(sender) ?? false)) {
          return;
        }
        if (!persistEnvelopePlaintext) {
          // Live path: durable journal only. No decrypt, no Drift row —
          // onPacket owns plaintext ingest.
          seenEventIds.add(id);
          messages[id] = ProjectedMessage(
            eventId: id,
            conversationId: record.fields['conversationId'] as String? ?? '',
            senderIdentity: sender,
            senderDeviceId: record.fields['senderDeviceId'] as String? ?? '',
            plaintext: '',
            status: 'pending',
            createdAt: (record.fields['createdAt'] as num?)?.toInt() ?? 0,
          );
          return;
        }
        // Opt-in replay path: a failed decrypt must not burn the event id.
        final enc = record.fields['encryptedEnvelope'];
        if (enc is! List<int>) return;
        final plain = await decrypt(enc, record);
        if (plain == null) return;
        seenEventIds.add(id);
        final chatId = (plain['id'] as String?) ?? '';
        final persistId = chatId.isNotEmpty ? chatId : id;
        final projected = ProjectedMessage(
          eventId: persistId,
          conversationId: record.fields['conversationId'] as String? ?? '',
          senderIdentity: record.fields['senderIdentity'] as String? ?? '',
          senderDeviceId: record.fields['senderDeviceId'] as String? ?? '',
          plaintext: plain['text'] as String? ?? '',
          status: 'delivered',
          createdAt: (record.fields['createdAt'] as num?)?.toInt() ?? 0,
        );
        messages[id] = projected;
        if (persistId != id) messages[persistId] = projected;
        await persist?.call(projected);
      case ReplicationEventKind.deliveryAcknowledged:
        final ackId = record.fields['eventId'] as String?;
        if (ackId == null) return;
        final acked = messages[ackId];
        if (acked != null) {
          messages[ackId] = acked.copyWith(status: 'delivered');
          await persist?.call(messages[ackId]!);
        }
      case ReplicationEventKind.readAcknowledged:
        final readId = record.fields['eventId'] as String?;
        if (readId == null) return;
        final read = messages[readId];
        if (read != null) {
          messages[readId] = read.copyWith(status: 'read');
          await persist?.call(messages[readId]!);
        }
      case ReplicationEventKind.messageTombstoned:
        final id = record.fields['eventId'] as String?;
        if (id == null) return;
        final existing = messages[id];
        if (existing == null) return;
        if (existing.senderDeviceId.isEmpty ||
            existing.senderDeviceId != record.writerDeviceId) {
          return;
        }
        messages.remove(id);
        await tombstone?.call(id);
      case ReplicationEventKind.roomMembershipChanged:
        final id = record.fields['eventId'] as String?;
        if (id == null || seenEventIds.contains(id)) return;
        seenEventIds.add(id);
        membershipChanges.add(<String, Object?>{
          'eventId': id,
          'roomId': record.fields['roomId'],
          'action': record.fields['action'],
          'memberPeerId': record.fields['memberPeerId'],
          'abWriter': record.fields['abWriter'],
          'abSeq': record.fields['abSeq'],
        });
      case ReplicationEventKind.deviceAuthorized:
      case ReplicationEventKind.deviceRevoked:
        applyOwnAccountDeviceRecord(
          record,
          devices: devices,
          ratchets: ratchets,
          selfPeerId: selfPeerId,
          localDeviceId: localDeviceId,
        );
      default:
        break;
    }
  }
}
