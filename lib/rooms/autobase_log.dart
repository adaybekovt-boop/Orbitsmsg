// Deterministic multiwriter projection for rooms (Phase 12).
// Does not encrypt. Host-plaintext warning stays in place.

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
          ? Map<String, Object?>.from(raw)
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
    state.applied.clear();
  }

  void apply(RoomEvent event) {
    final key = state.keyOf(event);
    if (state.applied.contains(key)) return;
    state.applied.add(key);
    switch (event.kind) {
      case 'membership':
        final peer = event.payload['peerId'] as String?;
        final action = event.payload['action'] as String? ?? 'join';
        if (peer == null) return;
        if (action == 'leave' || action == 'kick') {
          state.members.remove(peer);
          state.roles.remove(peer);
        } else {
          state.members[peer] = event.payload['displayName'] as String? ?? peer;
        }
      case 'role':
        final peer = event.payload['peerId'] as String?;
        final role = event.payload['role'] as String?;
        if (peer != null && role != null) state.roles[peer] = role;
      case 'channel':
        final id = event.payload['id'] as String?;
        final name = event.payload['name'] as String?;
        if (id != null && name != null) state.channels[id] = name;
      case 'message':
        state.messages.add(Map<String, Object?>.from(event.payload));
      case 'moderation':
        final id = event.payload['messageId'] as String?;
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
