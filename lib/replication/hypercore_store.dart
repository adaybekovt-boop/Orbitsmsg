// Local Hypercore stand-in: append-only encrypted blocks. Syncs over
// TransportChannel.replication. Never stores plaintext.

import 'dart:convert';

import '../peer/helpers.dart';
import '../transport/layers.dart';
import '../transport/replication_schema.dart';
import 'memory_journal.dart';
import 'replication_authorization.dart';

class HypercoreLocalStore {
  HypercoreLocalStore(this.writerDeviceId);

  final String writerDeviceId;
  final List<JournalRecord> blocks = <JournalRecord>[];

  JournalRecord append(JournalRecord record) {
    if (!replicationFieldsAreSafe(record.fields.keys)) {
      throw ArgumentError('refusing secret field in hypercore');
    }
    blocks.add(record);
    return record;
  }

  /// Contact-scoped filter. Unscoped / device records are excluded.
  List<JournalRecord> recordsForConversations(Set<String> authorizedConversations) {
    final allowed = authorizedConversations.map(normalizePeerId).toSet();
    return blocks.where((r) {
      if (isOwnerDeviceScopedKind(r.kind)) return false;
      final cid = normalizedConversationId(r.fields);
      return cid != null && allowed.contains(cid);
    }).toList(growable: false);
  }

  List<JournalRecord> recordsAuthorizedForPeer({
    required String authenticatedPeerId,
    required String selfPeerId,
    required bool peerIsOwnDevice,
  }) {
    return blocks
        .where(
          (r) => recordMayReplicateTo(
            r,
            authenticatedPeerId: authenticatedPeerId,
            selfPeerId: selfPeerId,
            peerIsOwnDevice: peerIsOwnDevice,
          ),
        )
        .toList(growable: false);
  }

  Map<String, Object?> toReplicationFrame(
    JournalRecord record, {
    Set<String>? authorizedConversations,
    String? authenticatedPeerId,
    String? selfPeerId,
    bool peerIsOwnDevice = false,
  }) {
    if (authenticatedPeerId != null) {
      if (!recordMayReplicateTo(
        record,
        authenticatedPeerId: authenticatedPeerId,
        selfPeerId: selfPeerId ?? '',
        peerIsOwnDevice: peerIsOwnDevice,
      )) {
        throw StateError(
          'refusing to replicate record ${record.kind.name} to $authenticatedPeerId',
        );
      }
    } else if (authorizedConversations != null) {
      final cid = normalizedConversationId(record.fields);
      final allowed = authorizedConversations.map(normalizePeerId).toSet();
      if (cid == null || !allowed.contains(cid)) {
        throw StateError(
          'refusing to replicate record for unauthorized conversation: $cid',
        );
      }
    }
    return <String, Object?>{
      'type': 'repl-event',
      'info': kReplicationEventInfo,
      'kind': record.kind.name,
      'seq': record.seq,
      'writerDeviceId': record.writerDeviceId,
      'fields': record.fields.map((k, v) {
        if (v is List<int>) return MapEntry(k, base64Encode(v));
        return MapEntry(k, v);
      }),
    };
  }

  JournalRecord? applyRemote(
    Map<String, Object?> frame, {
    Set<String>? authorizedConversations,
    String? authenticatedPeerId,
    String? selfPeerId,
    bool peerIsOwnDevice = false,
  }) {
    if (frame['type'] != 'repl-event') return null;
    if (frame['info'] != kReplicationEventInfo) return null;
    final kindName = frame['kind'] as String?;
    if (kindName == null) return null;
    final kind = ReplicationEventKind.values.where((k) => k.name == kindName);
    if (kind.isEmpty) return null;
    final raw = frame['fields'];
    if (raw is! Map) return null;
    final fields = <String, Object?>{};
    raw.forEach((k, v) {
      if (k == 'encryptedEnvelope' && v is String) {
        fields[k] = base64Decode(v);
      } else {
        fields[k as String] = v;
      }
    });
    if (!replicationFieldsAreSafe(fields.keys)) return null;

    if (authenticatedPeerId != null) {
      if (!frameMayAcceptFrom(
        kind.first,
        fields,
        authenticatedPeerId: authenticatedPeerId,
        selfPeerId: selfPeerId ?? '',
        peerIsOwnDevice: peerIsOwnDevice,
      )) {
        return null;
      }
    } else if (authorizedConversations != null) {
      final cid = normalizedConversationId(fields);
      final allowed = authorizedConversations.map(normalizePeerId).toSet();
      if (cid == null || !allowed.contains(cid)) {
        return null;
      }
    }

    final record = JournalRecord(
      seq: frame['seq'] as int? ?? blocks.length,
      writerDeviceId: frame['writerDeviceId'] as String? ?? '',
      kind: kind.first,
      fields: fields,
    );
    return append(record);
  }
}
