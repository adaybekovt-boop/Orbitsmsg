// A.4 — sendRoomPacket must honor the host-plaintext session ack.
// The UI banner is not a security boundary if the wire send ignores it.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/room_plaintext_gate.dart';

void main() {
  setUp(kRoomPlaintextSessionAck.reset);
  tearDown(kRoomPlaintextSessionAck.reset);

  test('sendRoomPacket blocks room_msg without session ack', () {
    expect(kRoomPlaintextSessionAck.isAcknowledged, isFalse);
    final sent = <Map<String, Object?>>[];
    final ok = sendGuardedRoomPacket(
      {'type': 'room_msg', 'text': 'hello from bypass'},
      connected: true,
      send: sent.add,
    );
    expect(ok, isFalse, reason: 'wire send must refuse un-acked room_msg');
    expect(sent, isEmpty);
  });

  test('sendRoomPacket allows room_msg after ack', () {
    kRoomPlaintextSessionAck.setAcknowledged(true);
    final sent = <Map<String, Object?>>[];
    final packet = {'type': 'room_msg', 'text': 'ok'};
    final ok = sendGuardedRoomPacket(
      packet,
      connected: true,
      send: sent.add,
    );
    expect(ok, isTrue);
    expect(sent, [packet]);
  });

  test('sendRoomPacket blocks room_file_chunk without session ack', () {
    expect(kRoomPlaintextSessionAck.isAcknowledged, isFalse);
    final sent = <Map<String, Object?>>[];
    final ok = sendGuardedRoomPacket(
      {
        'type': 'room_file_chunk',
        'id': 'f1',
        'offset': 0,
        'b64': 'AQIDBA==',
      },
      connected: true,
      send: sent.add,
    );
    expect(
      ok,
      isFalse,
      reason: 'wire send must refuse un-acked room_file_chunk',
    );
    expect(sent, isEmpty);
  });

  test('sendRoomPacket allows room_file_chunk after ack', () {
    kRoomPlaintextSessionAck.setAcknowledged(true);
    final sent = <Map<String, Object?>>[];
    final packet = {
      'type': 'room_file_chunk',
      'id': 'f1',
      'offset': 0,
      'b64': 'AQIDBA==',
    };
    expect(
      sendGuardedRoomPacket(packet, connected: true, send: sent.add),
      isTrue,
    );
    expect(sent, [packet]);
  });

  test('control packets still send without ack', () {
    final sent = <Map<String, Object?>>[];
    final ok = sendGuardedRoomPacket(
      {'type': 'room_join', 'roomId': 'r'},
      connected: true,
      send: sent.add,
    );
    expect(ok, isTrue);
    expect(sent.single['type'], 'room_join');
  });

  test('sendRoomPacket refuses nested fileKey after ack', () {
    kRoomPlaintextSessionAck.setAcknowledged(true);
    final sent = <Map<String, Object?>>[];
    final ok = sendGuardedRoomPacket(
      {
        'type': 'room_msg',
        'text': 'hello',
        'meta': {'fileKey': 'x'},
      },
      connected: true,
      send: sent.add,
    );
    expect(ok, isFalse, reason: 'nested fileKey must never leave the host');
    expect(sent, isEmpty);
  });

  test('sendRoomPacket refuses nested kek on room_file_chunk after ack', () {
    kRoomPlaintextSessionAck.setAcknowledged(true);
    final sent = <Map<String, Object?>>[];
    final ok = sendGuardedRoomPacket(
      {
        'type': 'room_file_chunk',
        'id': 'f1',
        'offset': 0,
        'b64': 'AQIDBA==',
        'extra': {'kek': 'x'},
      },
      connected: true,
      send: sent.add,
    );
    expect(ok, isFalse, reason: 'nested kek must never leave the host');
    expect(sent, isEmpty);
  });

  test('control room_join with nested rootKey is refused without ack', () {
    expect(kRoomPlaintextSessionAck.isAcknowledged, isFalse);
    final sent = <Map<String, Object?>>[];
    final ok = sendGuardedRoomPacket(
      {
        'type': 'room_join',
        'roomId': 'r',
        'meta': {'rootKey': 'x'},
      },
      connected: true,
      send: sent.add,
    );
    expect(ok, isFalse, reason: 'secrets never send, even on control packets');
    expect(sent, isEmpty);
  });

  test('disconnected peer is not a silent ack bypass', () {
    kRoomPlaintextSessionAck.setAcknowledged(true);
    final sent = <Map<String, Object?>>[];
    expect(
      sendGuardedRoomPacket(
        {'type': 'room_msg', 'text': 'x'},
        connected: false,
        send: sent.add,
      ),
      isFalse,
    );
    expect(sent, isEmpty);
  });
}
