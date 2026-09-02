// Deterministic multiwriter projection for rooms (Phase 12).
// Does not encrypt. Host-plaintext warning stays in place.

import 'dart:collection';

import '../transport/layers.dart';

/// Autobase attachment extras already used in JS `STRIP`
/// (`tool/connectivity_harness/src/autobase.js`). Not live `text`.
const Set<String> _kAutobaseAttachmentStripExtras = <String>{
  'b64',
  'dataB64',
  'bytes',
};

bool _isStrippedAutobaseKey(String key) =>
    kForbiddenReplicationFields.contains(key) ||
    _kAutobaseAttachmentStripExtras.contains(key);

/// Live Autobase / room envelopes. True iff no [kForbiddenReplicationFields]
/// key appears at any depth. Same cycle-safe Map / Iterable walk as
/// [replicationValueIsSafe] (`text`, `b64`, and `peerId` are not forbidden).
bool autobaseLiveEnvelopeIsSafe(Object? value) =>
    replicationValueIsSafe(value);

/// Drop Hypercore-forbidden secrets and Autobase attachment extras
/// (`b64`, `dataB64`, `bytes`) from an Autobase event payload at any depth.
/// Host-plaintext `text` stays in the local projection.
/// Residual strip for a **clean** envelope — refuse first with
/// [autobaseLiveEnvelopeIsSafe].
Map<String, Object?> stripForbiddenAutobasePayload(Map<String, Object?> raw) {
  final out = <String, Object?>{};
  for (final entry in raw.entries) {
    if (_isStrippedAutobaseKey(entry.key)) continue;
    out[entry.key] = _stripForbiddenAutobaseNested(entry.value);
  }
  return out;
}

/// Recurse into Map / Map-like values and into List/Iterable elements
/// (except String, which is also an Iterable). Ciphertext `List<int>` /
/// `Uint8List` have no named keys and pass through unchanged.
Object? _stripForbiddenAutobaseNested(Object? value) {
  if (value is Map) {
    final asStringKeyed = value is Map<String, Object?>
        ? value
        : <String, Object?>{
            for (final e in value.entries)
              if (e.key is String) e.key as String: e.value,
          };
    return stripForbiddenAutobasePayload(asStringKeyed);
  }
  if (value is Iterable && value is! String) {
    return <Object?>[
      for (final element in value) _stripForbiddenAutobaseNested(element),
    ];
  }
  return value;
}

/// Identifier keys copied as ids. Do not treat `peerId` as a forbidden
/// *key* — only refuse empty / URL-shaped *values* when present.
const Set<String> _kRoomIdentifierKeys = <String>{
  'roomId',
  'peerId',
  'guestPeerId',
  'id',
  'channelId',
  'messageId',
};

bool _roomIdentifierValueSafe(Object? value) {
  if (value == null) return true; // optional absent
  if (value is! String) return false;
  return value.isNotEmpty && !value.contains('://');
}

bool _roomPayloadIdentifiersSafe(Object? payload) {
  if (payload is! Map) return true;
  for (final key in _kRoomIdentifierKeys) {
    if (!payload.containsKey(key)) continue;
    if (!_roomIdentifierValueSafe(payload[key])) return false;
  }
  return true;
}

/// Journal kinds that rebuild Autobase membership after restart.
/// Mirrors `JOURNAL_MEMBERSHIP_KINDS` in `autobase.js`.
const Set<String> kAutobaseJournalMembershipKinds = {
  'roomMembershipChanged',
  'RoomMembershipChanged',
};

/// Journal hydrate extra bans. Live Autobase keeps host-plaintext `text`;
/// the restart path must not copy message bodies or chunk `b64`.
const Set<String> _kAutobaseJournalHydrateForbidden = {
  'text',
  'b64',
};

bool _autobaseJournalHydrateForbidden(Object? value, [Set<Object>? seen]) {
  if (value == null || value is bool || value is num || value is String) {
    return false;
  }
  if (value is List<int>) return false;
  final walk = seen ?? HashSet<Object>.identity();
  if (value is Map) {
    if (!walk.add(value)) return false;
    for (final e in value.entries) {
      final key = '${e.key}';
      if (kForbiddenReplicationFields.contains(key) ||
          _kAutobaseJournalHydrateForbidden.contains(key)) {
        return true;
      }
      if (_autobaseJournalHydrateForbidden(e.value, walk)) return true;
    }
    return false;
  }
  if (value is Iterable) {
    if (!walk.add(value)) return false;
    for (final item in value) {
      if (_autobaseJournalHydrateForbidden(item, walk)) return true;
    }
    return false;
  }
  return false;
}

Map<String, Object?>? _journalFieldsOf(Map<String, Object?> row) {
  final fields = row['fields'];
  if (fields is Map) {
    return <String, Object?>{
      for (final e in fields.entries)
        if (e.key is String) e.key as String: e.value,
    };
  }
  return row;
}

/// Map a worklet / loopback journal row to a membership event.
/// Only `roomMembershipChanged`. Never ciphertext, `text`, or `fileKey`.
RoomEvent? membershipEventFromJournalRow(Map<String, Object?> row) {
  final kindName = row['kind'];
  if (kindName is! String ||
      !kAutobaseJournalMembershipKinds.contains(kindName)) {
    return null;
  }
  if (_autobaseJournalHydrateForbidden(row)) return null;
  final fields = _journalFieldsOf(row);
  if (fields == null || _autobaseJournalHydrateForbidden(fields)) {
    return null;
  }
  final peerId = fields['peerId'];
  if (peerId is! String || peerId.isEmpty) return null;
  final payload = <String, Object?>{};
  for (final key in const ['peerId', 'action', 'displayName', 'roomId']) {
    if (!fields.containsKey(key)) continue;
    final value = fields[key];
    if (key == 'peerId' || key == 'action' || key == 'displayName') {
      if (value is! String || value.isEmpty) continue;
    } else if (value == null || value == '') {
      continue;
    }
    payload[key] = value;
  }
  if (payload['peerId'] == null) return null;
  if (!_roomPayloadIdentifiersSafe(payload)) return null;
  payload.putIfAbsent('action', () => 'join');
  final fromFields = fields['writerId'];
  final fromRow = row['writerDeviceId'] ?? row['writerId'];
  final writer = fromFields is String && fromFields.isNotEmpty
      ? fromFields
      : fromRow is String && fromRow.isNotEmpty
          ? fromRow
          : 'journal';
  if (writer.contains('://')) return null;
  final seq = (fields['seq'] as num?)?.toInt() ??
      (row['seq'] as num?)?.toInt() ??
      0;
  return RoomEvent(
    writerId: writer,
    seq: seq,
    kind: 'membership',
    payload: payload,
  );
}

class RoomEvent {
  const RoomEvent({
    required this.writerId,
    required this.seq,
    required this.kind,
    required this.payload,
  });

  final String writerId;
  final int seq;
  final String kind;
  final Map<String, Object?> payload;

  Map<String, Object?> toWire() => <String, Object?>{
        'type': 'autobase-event',
        'writerId': writerId,
        'seq': seq,
        'kind': kind,
        'payload': stripForbiddenAutobasePayload(payload),
      };

  static RoomEvent? fromWire(Map<String, Object?> packet) {
    if (packet['type'] != 'autobase-event') return null;
    // Refuse the whole envelope before strip — type / writer / kind / payload.
    if (!autobaseLiveEnvelopeIsSafe(packet)) return null;
    final writer = packet['writerId'] as String?;
    final kind = packet['kind'] as String?;
    if (writer == null || kind == null) return null;
    if (writer.contains('://') || kind.contains('://')) return null;
    final raw = packet['payload'];
    if (raw is Map && !_roomPayloadIdentifiersSafe(raw)) return null;
    return RoomEvent(
      writerId: writer,
      seq: (packet['seq'] as num?)?.toInt() ?? 0,
      kind: kind,
      payload: raw is Map
          ? stripForbiddenAutobasePayload(Map<String, Object?>.from(raw))
          : <String, Object?>{},
    );
  }
}

/// Live frames: `abWriter` may differ from the authenticated sender
/// only when that sender is the room host. Guests may claim their peer
/// id or device id. Membership control from a non-host is refused once
/// a host is known. No auth context → unchanged parse (unit tests).
bool _liveRoomEventAuthorized({
  required String claimedWriter,
  required String? roomId,
  required bool membership,
  String? authenticatedPeer,
  String? authenticatedDeviceId,
  String? Function(String roomId)? roomHostFor,
}) {
  if (authenticatedPeer == null) return true;
  final host = (roomId != null && roomId.isNotEmpty)
      ? roomHostFor?.call(roomId)
      : null;
  if (host == null || host.isEmpty) return true;
  final isHost = host == authenticatedPeer || host == authenticatedDeviceId;
  if (isHost) return true;
  final writerOk = claimedWriter == authenticatedPeer ||
      (authenticatedDeviceId != null &&
          claimedWriter == authenticatedDeviceId);
  if (!writerOk) return false;
  if (membership) return false;
  return true;
}

/// Map the live host-plaintext room protocol onto Autobase events.
/// Message bodies stay in the local projection — never Hypercore.
RoomEvent? roomEventFromNativePacket(
  Map<String, Object?> packet, {
  required String fallbackWriter,
  String? authenticatedPeer,
  String? authenticatedDeviceId,
  String? Function(String roomId)? roomHostFor,
}) {
  if (!autobaseLiveEnvelopeIsSafe(packet)) return null;
  if (fallbackWriter.contains('://')) return null;
  final abWriter = packet['abWriter'] as String?;
  if (abWriter != null && abWriter.contains('://')) return null;
  if (packet['type'] == 'autobase-event') {
    final ev = RoomEvent.fromWire(packet);
    if (ev == null) return null;
    if (!_liveRoomEventAuthorized(
      claimedWriter: ev.writerId,
      roomId: ev.payload['roomId'] as String?,
      membership: ev.kind == 'membership',
      authenticatedPeer: authenticatedPeer,
      authenticatedDeviceId: authenticatedDeviceId,
      roomHostFor: roomHostFor,
    )) {
      return null;
    }
    return ev;
  }
  final writer = abWriter ?? fallbackWriter;
  if (!_liveRoomEventAuthorized(
    claimedWriter: writer,
    roomId: packet['roomId'] as String?,
    membership: packet['type'] == 'room_join' ||
        packet['type'] == 'room_leave' ||
        packet['type'] == 'room_destroy',
    authenticatedPeer: authenticatedPeer,
    authenticatedDeviceId: authenticatedDeviceId,
    roomHostFor: roomHostFor,
  )) {
    return null;
  }
  final seq = (packet['abSeq'] as num?)?.toInt() ?? 0;
  switch (packet['type']) {
    case 'room_join':
      final peer =
          packet['guestPeerId'] as String? ?? packet['peerId'] as String?;
      if (peer == null || !_roomIdentifierValueSafe(peer)) return null;
      if (packet['roomId'] != null &&
          !_roomIdentifierValueSafe(packet['roomId'])) {
        return null;
      }
      return RoomEvent(
        writerId: writer,
        seq: seq,
        kind: 'membership',
        payload: {
          if (packet['roomId'] != null) 'roomId': packet['roomId'],
          'peerId': peer,
          'action': 'join',
          'displayName': packet['guestName'] as String? ?? peer,
        },
      );
    case 'room_leave':
    case 'room_destroy':
      final peer =
          packet['guestPeerId'] as String? ?? packet['peerId'] as String?;
      if (peer == null || !_roomIdentifierValueSafe(peer)) return null;
      if (packet['roomId'] != null &&
          !_roomIdentifierValueSafe(packet['roomId'])) {
        return null;
      }
      return RoomEvent(
        writerId: writer,
        seq: seq,
        kind: 'membership',
        payload: {
          if (packet['roomId'] != null) 'roomId': packet['roomId'],
          'peerId': peer,
          'action': 'leave',
        },
      );
    case 'room_channel_create':
      final raw = packet['channel'];
      final channel = raw is Map ? Map<String, Object?>.from(raw) : packet;
      final id = channel['id'] as String?;
      final name = channel['name'] as String?;
      if (id == null || name == null) return null;
      if (!_roomIdentifierValueSafe(id)) return null;
      return RoomEvent(
        writerId: writer,
        seq: seq,
        kind: 'channel',
        payload: {'id': id, 'name': name},
      );
    case 'room_msg':
      if (packet['id'] != null && !_roomIdentifierValueSafe(packet['id'])) {
        return null;
      }
      return RoomEvent(
        writerId: writer,
        seq: seq,
        kind: 'message',
        payload: {
          'id': packet['id'],
          'text': packet['text'],
        },
      );
    case 'room_file_chunk':
      final offset = (packet['offset'] as num?)?.toInt() ?? 0;
      if (offset != 0) return null;
      final id = packet['id'];
      if (id == null || !_roomIdentifierValueSafe(id)) return null;
      if (packet['roomId'] != null &&
          !_roomIdentifierValueSafe(packet['roomId'])) {
        return null;
      }
      if (packet['channelId'] != null &&
          !_roomIdentifierValueSafe(packet['channelId'])) {
        return null;
      }
      final rawAtt = packet['attachment'];
      final att = rawAtt is Map
          ? Map<String, Object?>.from(rawAtt)
          : <String, Object?>{};
      return RoomEvent(
        writerId: writer,
        seq: seq,
        kind: 'attachment',
        payload: {
          'id': id,
          'name': att['name'],
          'size': att['size'] ?? packet['total'],
          'mime': att['mime'],
          if (packet['roomId'] != null) 'roomId': packet['roomId'],
          if (packet['channelId'] != null) 'channelId': packet['channelId'],
        },
      );
    default:
      return null;
  }
}

class RoomState {
  RoomState();

  final Map<String, String> members = <String, String>{};
  final Map<String, String> roles = <String, String>{};
  final Map<String, String> channels = <String, String>{};
  final List<Map<String, Object?>> messages = <Map<String, Object?>>[];
  final Map<String, Map<String, Object?>> attachments =
      <String, Map<String, Object?>>{};
  final Set<String> applied = <String>{};

  String keyOf(RoomEvent e) => '${e.writerId}:${e.seq}';
}

class AutobaseProjection {
  final RoomState state = RoomState();

  void reset() {
    state.members.clear();
    state.roles.clear();
    state.channels.clear();
    state.messages.clear();
    state.attachments.clear();
    state.applied.clear();
  }

  void apply(RoomEvent event) {
    final key = state.keyOf(event);
    if (state.applied.contains(key)) return;
    // Refuse without marking applied so a later clean writer:seq can land.
    if (!autobaseLiveEnvelopeIsSafe(<String, Object?>{
          'kind': event.kind,
          'payload': event.payload,
          'writerId': event.writerId,
        })) {
      return;
    }
    if (event.writerId.contains('://') || event.kind.contains('://')) return;
    if (!_roomPayloadIdentifiersSafe(event.payload)) return;
    state.applied.add(key);
    final payload = stripForbiddenAutobasePayload(event.payload);
    switch (event.kind) {
      case 'membership':
        final peer = payload['peerId'] as String?;
        final action = payload['action'] as String? ?? 'join';
        if (peer == null) return;
        if (action == 'leave' || action == 'kick') {
          state.members.remove(peer);
          state.roles.remove(peer);
        } else {
          state.members[peer] = payload['displayName'] as String? ?? peer;
        }
      case 'role':
        final peer = payload['peerId'] as String?;
        final role = payload['role'] as String?;
        if (peer != null && role != null) state.roles[peer] = role;
      case 'channel':
        final id = payload['id'] as String?;
        final name = payload['name'] as String?;
        if (id != null && name != null) state.channels[id] = name;
      case 'message':
        state.messages.add(payload);
      case 'attachment':
        final id = payload['id'] as String?;
        if (id == null) return;
        state.attachments[id] = payload..remove('b64');
      case 'moderation':
        final id = payload['messageId'] as String?;
        if (id != null) {
          state.messages.removeWhere((m) => m['id'] == id);
        }
    }
  }

  void applyAll(Iterable<RoomEvent> events) {
    final sorted = events.toList()
      ..sort((a, b) {
        final bySeq = a.seq.compareTo(b.seq);
        if (bySeq != 0) return bySeq;
        return a.writerId.compareTo(b.writerId);
      });
    for (final event in sorted) {
      apply(event);
    }
  }

  /// Restart path. Membership metadata only — never message bodies.
  int hydrateFromJournal(Iterable<Object?> rows) {
    final events = <RoomEvent>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final event = membershipEventFromJournalRow(
        row is Map<String, Object?>
            ? row
            : <String, Object?>{
                for (final e in row.entries)
                  if (e.key is String) e.key as String: e.value,
              },
      );
      if (event != null) events.add(event);
    }
    applyAll(events);
    return events.length;
  }

  /// Same shape as JS `AutobaseProjection.snapshot()`. Never fileKey.
  Map<String, Object?> snapshot() => <String, Object?>{
        'members': Map<String, String>.from(state.members),
        'roles': Map<String, String>.from(state.roles),
        'channels': Map<String, String>.from(state.channels),
        'messages': <Map<String, Object?>>[
          for (final m in state.messages) Map<String, Object?>.from(m),
        ],
        'attachments': <String, Map<String, Object?>>{
          for (final e in state.attachments.entries)
            e.key: Map<String, Object?>.from(e.value),
        },
        'applied': state.applied.toList(),
      };
}
