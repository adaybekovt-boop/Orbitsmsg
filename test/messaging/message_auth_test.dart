// Phase 4: edit/delete/ack must match conversation + direction.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/messaging/message_auth.dart';

void main() {
  const alice = 'ORBIT-AAAAAA';
  const bob = 'ORBIT-BBBBBB';

  test('remote can edit/delete only inbound rows in this chat', () {
    expect(
      remoteOwnsInboundMessage(alice, {'peerId': alice, 'direction': 'in'}),
      isTrue,
    );
    expect(
      remoteOwnsInboundMessage(alice, {'peerId': alice, 'direction': 'out'}),
      isFalse,
    );
    expect(
      remoteOwnsInboundMessage(alice, {'peerId': bob, 'direction': 'in'}),
      isFalse,
    );
    expect(remoteOwnsInboundMessage(alice, null), isFalse);
  });

  test('remote can ACK only outbound rows we sent them', () {
    expect(
      remoteCanAckOutbound(alice, {'peerId': alice, 'direction': 'out'}),
      isTrue,
    );
    expect(
      remoteCanAckOutbound(alice, {'peerId': alice, 'direction': 'in'}),
      isFalse,
    );
    expect(
      remoteCanAckOutbound('  orbit-aaaaaa  ', {
        'peerId': 'orbit-aaaaaa',
        'direction': 'out',
      }),
      isTrue,
    );
  });
}
