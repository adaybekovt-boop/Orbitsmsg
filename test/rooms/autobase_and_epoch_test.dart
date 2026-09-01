import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/room_disclaimer.dart';
import 'package:orbits_flutter/rooms/autobase_log.dart';
import 'package:orbits_flutter/rooms/sender_key_epoch.dart';

void main() {
  test('two writers converge in any apply order', () {
    final events = [
      const RoomEvent(
        writerId: 'b',
        seq: 0,
        kind: 'membership',
        payload: {'peerId': 'b', 'action': 'join', 'displayName': 'B'},
      ),
      const RoomEvent(
        writerId: 'a',
        seq: 0,
        kind: 'membership',
        payload: {'peerId': 'a', 'action': 'join', 'displayName': 'A'},
      ),
      const RoomEvent(
        writerId: 'a',
        seq: 1,
        kind: 'channel',
        payload: {'id': 'c1', 'name': 'general'},
      ),
      const RoomEvent(
        writerId: 'b',
        seq: 1,
        kind: 'message',
        payload: {'id': 'm1', 'text': 'hi'},
      ),
    ];
    final left = AutobaseProjection()..applyAll(events);
    final right = AutobaseProjection()..applyAll(events.reversed);
    expect(left.state.members, right.state.members);
    expect(left.state.channels, right.state.channels);
    expect(left.state.messages, right.state.messages);
    final rebuilt = AutobaseProjection()
      ..reset()
      ..applyAll(events.reversed);
    expect(rebuilt.state.members, left.state.members);
    expect(
      RoomEvent.fromWire(events.last.toWire())?.kind,
      'message',
    );
    expect(
      roomEventFromNativePacket(
        {
          'type': 'room_join',
          'abWriter': 'a',
          'abSeq': 0,
          'guestPeerId': 'p1',
          'guestName': 'Pat',
        },
        fallbackWriter: 'x',
      )?.kind,
      'membership',
    );
  });

  test('epoch rotate excludes the removed device', () {
    final epoch = SenderKeyEpoch(
      epochId: 1,
      memberDeviceIds: {'d1', 'd2', 'd3'},
      epochKey: const [1, 2, 3],
    );
    final next = epoch.rotateAfterRemoval('d2', const [9, 9, 9]);
    expect(next.epochId, 2);
    expect(next.accepts('d2'), isFalse);
    expect(next.canUnwrap('d2'), isFalse);
    expect(next.accepts('d1'), isTrue);
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('revoke then rejoin requires a new epoch key', () {
    var epoch = SenderKeyEpoch(
      epochId: 1,
      memberDeviceIds: {'d1', 'd2'},
      epochKey: const [1],
    );
    epoch = epoch.rotateAfterRemoval('d2', const [2]);
    expect(epoch.canUnwrap('d2'), isFalse);
    final rejoined = SenderKeyEpoch(
      epochId: epoch.epochId + 1,
      memberDeviceIds: {'d1', 'd2'},
      epochKey: const [3],
    );
    expect(rejoined.epochKey, isNot(epoch.epochKey));
    expect(rejoined.accepts('d2'), isTrue);
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });
}
