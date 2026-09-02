import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/room_disclaimer.dart';
import 'package:orbits_flutter/rooms/autobase_log.dart';
import 'package:orbits_flutter/rooms/sender_key_epoch.dart';
import 'package:orbits_flutter/transport/layers.dart';

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

  test('apply refuses nested fileKey/kek and does not consume writer:seq', () {
    final proj = AutobaseProjection()
      ..apply(
        const RoomEvent(
          writerId: 'a',
          seq: 1,
          kind: 'message',
          payload: {
            'id': 'm-hello',
            'text': 'hello',
            'fileKey': 'smuggle-file',
            'kek': 'smuggle-kek',
            'rootKey': 'smuggle-root',
            'discoverySecret': 'smuggle-disco',
          },
        ),
      );
    expect(proj.state.messages, isEmpty);
    expect(proj.state.members, isEmpty);
    expect(proj.state.applied, isEmpty);
    proj.apply(
      const RoomEvent(
        writerId: 'a',
        seq: 1,
        kind: 'message',
        payload: {'id': 'm-hello', 'text': 'hello'},
      ),
    );
    expect(proj.state.messages.single['text'], 'hello');
    expect(proj.state.applied, contains('a:1'));
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('apply refuses membership that nests fileKey', () {
    final proj = AutobaseProjection()
      ..apply(
        const RoomEvent(
          writerId: 'a',
          seq: 0,
          kind: 'membership',
          payload: {
            'peerId': 'eve',
            'action': 'join',
            'displayName': 'Eve',
            'extra': {'fileKey': 'x', 'kek': 'y'},
          },
        ),
      );
    expect(proj.state.members, isEmpty);
    expect(proj.state.messages, isEmpty);
    expect(proj.state.applied, isEmpty);
  });

  test('apply of a clean message keeps host-plaintext text', () {
    final proj = AutobaseProjection()
      ..apply(
        const RoomEvent(
          writerId: 'a',
          seq: 1,
          kind: 'message',
          payload: {'id': 'm-hello', 'text': 'hello'},
        ),
      );
    final stored = proj.state.messages.single;
    expect(stored['text'], 'hello');
    expect(stored['id'], 'm-hello');
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('apply attachment strips residual b64 on a clean envelope', () {
    final hostile = AutobaseProjection()
      ..apply(
        const RoomEvent(
          writerId: 'a',
          seq: 2,
          kind: 'attachment',
          payload: {
            'id': 'att-1',
            'name': 'note.bin',
            'b64': 'AQIDBA==',
            'fileKeyB64': 'c21lYWtlZA==',
            'fileKey': 'also-nope',
          },
        ),
      );
    expect(hostile.state.attachments, isEmpty);
    expect(hostile.state.applied, isEmpty);

    final proj = AutobaseProjection()
      ..apply(
        const RoomEvent(
          writerId: 'a',
          seq: 2,
          kind: 'attachment',
          payload: {
            'id': 'att-1',
            'name': 'note.bin',
            'b64': 'AQIDBA==',
          },
        ),
      );
    final stored = proj.state.attachments['att-1']!;
    expect(stored['name'], 'note.bin');
    expect(stored.containsKey('b64'), isFalse);
  });

  test('toWire strips nested forbidden payload keys and keeps text', () {
    const event = RoomEvent(
      writerId: 'a',
      seq: 4,
      kind: 'message',
      payload: {
        'id': 'm-wire',
        'text': 'hello host-plaintext',
        'fileKey': 'smuggle-file',
        'b64': 'AQIDBA==',
        'extra': {
          'fileKey': 'x',
        },
      },
    );
    final wired = event.toWire();
    expect(wired['type'], 'autobase-event');
    final payload = Map<String, Object?>.from(wired['payload']! as Map);
    expect(payload['text'], 'hello host-plaintext');
    expect(payload['id'], 'm-wire');
    expect(payload.containsKey('fileKey'), isFalse);
    expect(payload.containsKey('b64'), isFalse);
    final extra = Map<String, Object?>.from(payload['extra']! as Map);
    expect(extra.containsKey('fileKey'), isFalse);
    expect(event.payload.containsKey('fileKey'), isTrue);
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('fromWire refuses autobase-event that nests fileKey or plaintext', () {
    expect(
      RoomEvent.fromWire({
        'type': 'autobase-event',
        'writerId': 'a',
        'seq': 9,
        'kind': 'message',
        'payload': {
          'text': 'hello',
          'attachment': {
            'fileKey': 'x',
            'b64': 'AQID',
            'name': 'n',
          },
        },
      }),
      isNull,
    );
    expect(
      RoomEvent.fromWire({
        'type': 'autobase-event',
        'writerId': 'w',
        'seq': 3,
        'kind': 'message',
        'payload': {
          'id': 'm2',
          'text': 'still here',
          'plaintext': 'must-not-keep',
        },
      }),
      isNull,
    );
    final clean = RoomEvent.fromWire({
      'type': 'autobase-event',
      'writerId': 'w',
      'seq': 3,
      'kind': 'message',
      'payload': {
        'id': 'm2',
        'text': 'still here',
      },
    });
    expect(clean, isNotNull);
    expect(clean!.payload['text'], 'still here');
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('stripForbiddenAutobasePayload walks nested maps and keeps text', () {
    final cleaned = stripForbiddenAutobasePayload({
      'text': 'hello',
      'attachment': <dynamic, dynamic>{
        'fileKey': 'x',
        'b64': 'AQID',
        'name': 'n',
      },
    });
    expect(cleaned['text'], 'hello');
    expect(cleaned.containsKey('fileKey'), isFalse);
    expect(cleaned.containsKey('b64'), isFalse);
    final attachment = Map<String, Object?>.from(cleaned['attachment']! as Map);
    expect(attachment['name'], 'n');
    expect(attachment.containsKey('fileKey'), isFalse);
    expect(attachment.containsKey('b64'), isFalse);
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('fromWire of nested fileKey is null; apply does not project it', () {
    final wired = RoomEvent.fromWire({
      'type': 'autobase-event',
      'writerId': 'a',
      'seq': 9,
      'kind': 'message',
      'payload': {
        'text': 'hello',
        'attachment': {
          'fileKey': 'x',
          'b64': 'AQID',
          'name': 'n',
        },
      },
    });
    expect(wired, isNull);

    final proj = AutobaseProjection()
      ..apply(
        const RoomEvent(
          writerId: 'a',
          seq: 9,
          kind: 'message',
          payload: {
            'text': 'hello',
            'attachment': {
              'fileKey': 'x',
              'b64': 'AQID',
              'name': 'n',
            },
          },
        ),
      );
    expect(proj.state.messages, isEmpty);
    expect(proj.state.applied, isEmpty);
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('stripForbiddenAutobasePayload walks arrays of maps and keeps text', () {
    final cleaned = stripForbiddenAutobasePayload({
      'chunks': [
        {
          'fileKey': 'x',
          'b64': 'AQID',
          'name': 'n',
        },
      ],
      'text': 'hello',
    });
    expect(cleaned['text'], 'hello');
    expect(cleaned.containsKey('fileKey'), isFalse);
    expect(cleaned.containsKey('b64'), isFalse);
    final chunks = cleaned['chunks'] as List;
    expect(chunks, hasLength(1));
    final chunk = Map<String, Object?>.from(chunks.single as Map);
    expect(chunk['name'], 'n');
    expect(chunk.containsKey('fileKey'), isFalse);
    expect(chunk.containsKey('b64'), isFalse);
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('stripForbiddenAutobasePayload matches kForbiddenReplicationFields', () {
    expect(
      kForbiddenReplicationFields,
      containsAll(<String>{
        'plaintext',
        'password',
        'kek',
        'vaultKek',
        'rootKey',
        'sendCk',
        'recvCk',
        'dhPriv',
        'skipped',
        'discoverySecret',
        'sharedDiscoverySecret',
        'attachmentBytes',
        'fileKey',
        'fileKeyB64',
        'privBytes',
      }),
    );
    final raw = <String, Object?>{
      'text': 'hello',
      'id': 'm3',
      for (final key in kForbiddenReplicationFields) key: 'leaked-$key',
    };
    final cleaned = stripForbiddenAutobasePayload(raw);
    expect(cleaned['text'], 'hello');
    expect(cleaned['id'], 'm3');
    expect(cleaned.keys.toSet().intersection(kForbiddenReplicationFields), isEmpty);
    expect(
      raw.keys.toSet().difference(cleaned.keys.toSet()),
      kForbiddenReplicationFields,
    );
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('autobaseLiveEnvelopeIsSafe ignores text/b64/peerId and is cycle-safe',
      () {
    expect(kForbiddenReplicationFields.contains('text'), isFalse);
    expect(kForbiddenReplicationFields.contains('b64'), isFalse);
    expect(kForbiddenReplicationFields.contains('peerId'), isFalse);
    expect(
      autobaseLiveEnvelopeIsSafe({
        'type': 'room_msg',
        'text': 'hello',
        'b64': 'AQID',
        'peerId': 'p1',
      }),
      isTrue,
    );
    expect(
      autobaseLiveEnvelopeIsSafe({
        'text': 'hello',
        'meta': {'fileKey': 'x'},
      }),
      isFalse,
    );
    final cyclic = <String, Object?>{'text': 'ok', 'peerId': 'p', 'b64': 'x'};
    cyclic['self'] = cyclic;
    expect(autobaseLiveEnvelopeIsSafe(cyclic), isTrue);
    final cyclicBad = <String, Object?>{'kek': 'x'};
    cyclicBad['self'] = cyclicBad;
    expect(autobaseLiveEnvelopeIsSafe(cyclicBad), isFalse);
  });

  test('roomEventFromNativePacket refuses fileKey and discoverySecret', () {
    expect(
      roomEventFromNativePacket(
        {
          'type': 'room_join',
          'peerId': 'hostile',
          'guestName': 'Eve',
          'fileKey': 'smuggle-file',
          'abWriter': 'a',
          'abSeq': 0,
        },
        fallbackWriter: 'x',
      ),
      isNull,
    );
    expect(
      roomEventFromNativePacket(
        {
          'type': 'room_join',
          'guestPeerId': 'p1',
          'guestName': 'Pat',
          'extra': {'fileKey': 'x'},
          'abWriter': 'a',
          'abSeq': 0,
        },
        fallbackWriter: 'x',
      ),
      isNull,
    );
    expect(
      roomEventFromNativePacket(
        {
          'type': 'room_msg',
          'id': 'm-bad',
          'text': 'host-plaintext',
          'meta': {'discoverySecret': 'leaked-topic'},
          'abWriter': 'a',
          'abSeq': 1,
        },
        fallbackWriter: 'x',
      ),
      isNull,
    );
    expect(
      roomEventFromNativePacket(
        {
          'type': 'room_msg',
          'id': 'm-top',
          'text': 'hello',
          'fileKey': 'x',
          'abWriter': 'a',
          'abSeq': 1,
        },
        fallbackWriter: 'x',
      ),
      isNull,
    );
    expect(
      roomEventFromNativePacket(
        {
          'type': 'room_file_chunk',
          'id': 'f-bad',
          'offset': 0,
          'fileKey': 'nope',
          'attachment': {'name': 'note.bin'},
          'abWriter': 'a',
          'abSeq': 2,
        },
        fallbackWriter: 'x',
      ),
      isNull,
    );

    final join = roomEventFromNativePacket(
      {
        'type': 'room_join',
        'roomId': 'room-1',
        'abWriter': 'a',
        'abSeq': 0,
        'guestPeerId': 'p1',
        'guestName': 'Pat',
      },
      fallbackWriter: 'x',
    );
    expect(join?.kind, 'membership');
    expect(join?.payload['peerId'], 'p1');
    expect(join?.payload['displayName'], 'Pat');

    final msg = roomEventFromNativePacket(
      {
        'type': 'room_msg',
        'id': 'm1',
        'text': 'hello host-plaintext',
        'peerId': 'ORBIT-AA',
        'abWriter': 'a',
        'abSeq': 1,
      },
      fallbackWriter: 'x',
    );
    expect(msg?.kind, 'message');
    expect(msg?.payload['text'], 'hello host-plaintext');
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('apply refuses writerId scheme and does not mark applied', () {
    final proj = AutobaseProjection()
      ..apply(
        const RoomEvent(
          writerId: 'https://evil',
          seq: 0,
          kind: 'membership',
          payload: {
            'peerId': 'eve',
            'action': 'join',
            'displayName': 'Eve',
          },
        ),
      );
    expect(proj.state.members, isEmpty);
    expect(proj.state.applied, isEmpty);
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('fromWire refuses writerId scheme', () {
    expect(
      RoomEvent.fromWire({
        'type': 'autobase-event',
        'writerId': 'https://x',
        'seq': 0,
        'kind': 'membership',
        'payload': {
          'peerId': 'p1',
          'action': 'join',
        },
      }),
      isNull,
    );
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('roomEventFromNativePacket refuses abWriter scheme; legit join/msg work',
      () {
    expect(
      roomEventFromNativePacket(
        {
          'type': 'room_join',
          'roomId': 'room-1',
          'abWriter': 'https://x',
          'abSeq': 0,
          'guestPeerId': 'p1',
          'guestName': 'Pat',
        },
        fallbackWriter: 'a',
      ),
      isNull,
    );

    final join = roomEventFromNativePacket(
      {
        'type': 'room_join',
        'roomId': 'room-1',
        'abWriter': 'a',
        'abSeq': 0,
        'guestPeerId': 'p1',
        'guestName': 'Pat',
      },
      fallbackWriter: 'x',
    );
    expect(join?.kind, 'membership');
    expect(join?.writerId, 'a');
    expect(join?.payload['peerId'], 'p1');

    final msg = roomEventFromNativePacket(
      {
        'type': 'room_msg',
        'id': 'm1',
        'text': 'hello host-plaintext',
        'peerId': 'ORBIT-AA',
        'abWriter': 'a',
        'abSeq': 1,
      },
      fallbackWriter: 'x',
    );
    expect(msg?.kind, 'message');
    expect(msg?.payload['text'], 'hello host-plaintext');

    final proj = AutobaseProjection()..apply(msg!);
    expect(proj.state.messages.single['text'], 'hello host-plaintext');
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('worklet autobase.js projects kForbiddenReplicationFields', () {
    final js =
        File('tool/connectivity_harness/src/autobase.js').readAsStringSync();
    expect(js, contains('vaultKek'));
    expect(js, contains('sendCk'));
    expect(js, contains('fileKey'));
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });
}
