// Deterministic multiwriter projection for rooms (Phase 12).
// Does not encrypt. Host-plaintext warning stays in place.
// DualStack carries [kRoomAutobaseType] as a room_* control packet.

/// Host-plaintext Autobase event on the room control channel.
const String kRoomAutobaseType = 'room_autobase';

Map<String, Object?> encodeRoomAutobasePacket(String roomId, RoomEvent event) =>
    <String, Object?>{
      'type': kRoomAutobaseType,
      'roomId': roomId,
      'writerId': event.writerId,
      'seq': event.seq,
      'kind': event.kind,
      'payload': event.payload,
    };

RoomEvent? decodeRoomEventFromPacket(Map<String, Object?> packet) {
  final writerId = packet['writerId'] as String? ?? '';
  final kind = packet['kind'] as String? ?? '';
  final raw = packet['payload'];
  if (writerId.isEmpty || kind.isEmpty || raw is! Map) return null;
  return RoomEvent(
    writerId: writerId,
    seq: (packet['seq'] as num?)?.toInt() ?? 0,
    kind: kind,
    payload: Map<String, Object?>.from(raw),
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
  AutobaseProjection({Set<String>? revokedWriters})
    : revokedWriters = revokedWriters ?? <String>{};

  final RoomState state = RoomState();
  final Set<String> revokedWriters;

  void revokeWriter(String writerId) {
    revokedWriters.add(writerId);
  }

  void apply(RoomEvent event) {
    if (revokedWriters.contains(event.writerId)) return;
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

/// Local writer-seq tracker used by RoomManager. Payload stays host-plaintext.
class RoomAutobaseLog {
  RoomAutobaseLog({Set<String>? revokedWriters})
      : projection = AutobaseProjection(revokedWriters: revokedWriters);

  final AutobaseProjection projection;
  final Map<String, int> _seq = <String, int>{};
  final List<RoomEvent> events = <RoomEvent>[];

  int nextSeq(String writerId) =>
      _seq[writerId] = (_seq[writerId] ?? -1) + 1;

  RoomEvent append({
    required String writerId,
    required String kind,
    required Map<String, Object?> payload,
    int? seq,
  }) {
    final resolved = seq ?? nextSeq(writerId);
    if (seq != null) {
      final current = _seq[writerId] ?? -1;
      if (seq > current) _seq[writerId] = seq;
    }
    final event = RoomEvent(
      writerId: writerId,
      seq: resolved,
      kind: kind,
      payload: payload,
    );
    final already = projection.state.applied.contains(projection.state.keyOf(event));
    projection.apply(event);
    if (!already) events.add(event);
    return event;
  }

  void clear() {
    projection.state.members.clear();
    projection.state.roles.clear();
    projection.state.channels.clear();
    projection.state.messages.clear();
    projection.state.applied.clear();
    _seq.clear();
    events.clear();
  }
}
