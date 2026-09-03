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

  test('removed writer and conflicting roles still converge', () {
    final events = [
      const RoomEvent(
        writerId: 'a',
        seq: 0,
        kind: 'membership',
        payload: {'peerId': 'a', 'action': 'join', 'displayName': 'A'},
      ),
      const RoomEvent(
        writerId: 'b',
        seq: 0,
        kind: 'membership',
        payload: {'peerId': 'b', 'action': 'join', 'displayName': 'B'},
      ),
      const RoomEvent(
        writerId: 'a',
        seq: 1,
        kind: 'role',
        payload: {'peerId': 'b', 'role': 'mod'},
      ),
      const RoomEvent(
        writerId: 'b',
        seq: 1,
        kind: 'role',
        payload: {'peerId': 'b', 'role': 'member'},
      ),
      const RoomEvent(
        writerId: 'b',
        seq: 2,
        kind: 'message',
        payload: {'id': 'm-old', 'text': 'stale'},
      ),
    ];
    final left = AutobaseProjection()..applyAll(events);
    left.revokeWriter('b');
    left.apply(
      const RoomEvent(
        writerId: 'b',
        seq: 3,
        kind: 'message',
        payload: {'id': 'm-revoked', 'text': 'should-drop'},
      ),
    );
    final right = AutobaseProjection()..applyAll(events.reversed);
    right.revokeWriter('b');
    expect(left.state.roles['b'], right.state.roles['b']);
    expect(left.state.messages.any((m) => m['id'] == 'm-revoked'), isFalse);
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('skipped-epoch recovery is bounded and attachments wrap per epoch', () {
    var epoch = SenderKeyEpoch(
      epochId: 1,
      memberDeviceIds: {'d1', 'd2'},
      epochKey: List<int>.generate(32, (i) => i + 4),
    );
    epoch = epoch.rotateAfterRemoval('d2', List<int>.generate(32, (i) => i + 7));
    expect(epoch.canRecoverSkipped(1), isTrue);
    expect(epoch.canRecoverSkipped(1 - 10), isFalse);
    final fileKey = List<int>.generate(32, (i) => 32 - i);
    final wrapped = epoch.wrapAttachmentKey(fileKey);
    expect(epoch.unwrapAttachmentKey(wrapped, 'd1'), fileKey);
    expect(() => epoch.unwrapAttachmentKey(wrapped, 'd2'), throwsStateError);
    expect(epoch.toPersistedJson().containsKey('epochKey'), isFalse);
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });
}
