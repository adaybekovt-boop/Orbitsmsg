import 'package:flutter/foundation.dart';

/// Checkbox on the create/join sheet and the in-chat banner.
const Key kRoomPlaintextAckKey = Key('room-plaintext-ack');

const String kRoomPlaintextAckLabelRu =
    'Я понимаю: организатор видит все сообщения и файлы.';

/// Host-plaintext rooms: no create/join/send without an explicit ack.
bool roomPlaintextActionAllowed({required bool acknowledgedHostCanRead}) =>
    acknowledgedHostCanRead;

/// Session-scoped ack. UI banners/sheets write this; every production
/// [sendRoomPacket] reads it. Not a tautology: user content is blocked
/// until [setAcknowledged](true) in this process.
class RoomPlaintextSessionAck {
  bool _acked = false;

  bool get isAcknowledged => _acked;

  void setAcknowledged(bool value) => _acked = value;

  void reset() => _acked = false;

  /// Control packets (join/leave/members/…) always pass. `room_msg`
  /// (text / sticker / file) requires the disclaimer ack.
  bool allowsPacket(Map<String, Object?> packet) {
    if (packet['type'] != 'room_msg') return true;
    return _acked;
  }
}

final RoomPlaintextSessionAck kRoomPlaintextSessionAck =
    RoomPlaintextSessionAck();

/// Shared wire send used by [ConnectionsNotifier.sendRoomPacket] and
/// [RoomScopedTransport.sendRoomPacket].
bool sendGuardedRoomPacket(
  Map<String, Object?> packet, {
  required bool connected,
  required void Function(Map<String, Object?>) send,
}) {
  if (!kRoomPlaintextSessionAck.allowsPacket(packet)) return false;
  if (!connected) return false;
  send(packet);
  return true;
}
