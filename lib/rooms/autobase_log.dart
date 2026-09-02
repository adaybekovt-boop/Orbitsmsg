// Deterministic multiwriter projection for rooms (Phase 12).
// Does not encrypt. Host-plaintext warning stays in place.

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

/// Drop Hypercore-forbidden secrets and Autobase attachment extras
/// (`b64`, `dataB64`, `bytes`) from an Autobase event payload at any depth.
/// Host-plaintext `text` stays in the local projection.
Map<String, Object?> stripForbiddenAutobasePayload(Map<String, Object?> raw) {
  final out = <String, Object?>{};
  for (final entry in raw.entries) {
    if (_isStrippedAutobaseKey(entry.key)) continue;
    out[entry.key] = _stripForbiddenAutobaseNested(entry.value);
  }
  return out;
}

/// Recurse into Map / Map-like nested maps. Arrays stay opaque, matching JS
/// `sanitize` (it returns arrays unchanged).
Object? _stripForbiddenAutobaseNested(Object? value) {
  if (value is! Map) return value;
  final asStringKeyed = value is Map<String, Object?>
      ? value
      : <String, Object?>{
          for (final e in value.entries)
            if (e.key is String) e.key as String: e.value,
        };
  return stripForbiddenAutobasePayload(asStringKeyed);
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
        'payload': payload,
      };

  static RoomEvent? fromWire(Map<String, Object?> packet) {
    if (packet['type'] != 'autobase-event') return null;
    final writer = packet['writerId'] as String?;
    final kind = packet['kind'] as String?;
    if (writer == null || kind == null) return null;
    final raw = packet['payload'];
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

/// Map the live host-plaintext room protocol onto Autobase events.
/// Message bodies stay in the local projection — never Hypercore.
RoomEvent? roomEventFromNativePacket(
  Map<String, Object?> packet, {
  required String fallbackWriter,
}) {
  if (packet['type'] == 'autobase-event') return RoomEvent.fromWire(packet);
  final writer = packet['abWriter'] as String? ?? fallbackWriter;
  final seq = (packet['abSeq'] as num?)?.toInt() ?? 0;
  switch (packet['type']) {
    case 'room_join':
      final peer =
          packet['guestPeerId'] as String? ?? packet['peerId'] as String?;
      if (peer == null) return null;
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
      if (peer == null) return null;
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
      return RoomEvent(
        writerId: writer,
        seq: seq,
        kind: 'channel',
        payload: {'id': id, 'name': name},
      );
    case 'room_msg':
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
      if (id == null) return null;
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
}
