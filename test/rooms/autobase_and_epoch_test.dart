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
          'roomId': 'room-1',
          'abWriter': 'a',
          'abSeq': 0,
          'guestPeerId': 'p1',
          'guestName': 'Pat',
        },
        fallbackWriter: 'x',
      )?.payload['roomId'],
      'room-1',
    );
    final fileEvent = roomEventFromNativePacket(
      {
        'type': 'room_file_chunk',
        'id': 'f1',
        'roomId': 'r1',
        'channelId': 'c1',
        'offset': 0,
        'total': 4,
        'b64': 'AQIDBA==',
        'fileKey': 'nope',
        'attachment': {
          'name': 'note.bin',
          'size': 4,
          'mime': 'application/octet-stream',
        },
        'abWriter': 'a',
        'abSeq': 2,
      },
      fallbackWriter: 'x',
    );
    expect(fileEvent?.kind, 'attachment');
    expect(fileEvent?.payload['name'], 'note.bin');
    expect(fileEvent?.payload.containsKey('b64'), isFalse);
    expect(fileEvent?.payload.containsKey('fileKey'), isFalse);
    final later = roomEventFromNativePacket(
      {
        'type': 'room_file_chunk',
        'id': 'f1',
        'offset': 64,
        'b64': 'xxxx',
        'abWriter': 'a',
        'abSeq': 3,
      },
      fallbackWriter: 'a',
    );
    expect(later, isNull);
    final withFile = AutobaseProjection()..apply(fileEvent!);
    expect(withFile.state.attachments['f1']?['name'], 'note.bin');
    expect(withFile.state.attachments['f1']?.containsKey('b64'), isFalse);
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
