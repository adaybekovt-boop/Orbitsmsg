// Diagnostic state for the connection registry — verifies that a swallowed
// P2P dial failure is now surfaced into observable state (ConnectError) and
// that recording it never drops the live connected-peers set.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/state/connections_notifier.dart';

void main() {
  test('empty state has no connections and no error', () {
    const s = ConnectionsState.empty();
    expect(s.connectedPeerIds, isEmpty);
    expect(s.lastConnectError, isNull);
  });

  test('copyWith records a connect error without dropping connected peers', () {
    const s = ConnectionsState(connectedPeerIds: {'ORBIT-AAAAAA'});
    final withErr = s.copyWith(
      lastConnectError: const ConnectError(
        peerId: 'ORBIT-BBBBBB',
        channel: 'reliable',
        message: 'ICE failed',
        atMs: 42,
      ),
    );
    expect(withErr.connectedPeerIds, {'ORBIT-AAAAAA'});
    expect(withErr.lastConnectError!.peerId, 'ORBIT-BBBBBB');
    expect(withErr.lastConnectError!.channel, 'reliable');
    expect(withErr.lastConnectError!.message, 'ICE failed');

    // Updating connected peers must preserve the recorded error (sentinel).
    final updated = withErr.copyWith(connectedPeerIds: {'ORBIT-CCCCCC'});
    expect(updated.lastConnectError, isNotNull);
    expect(updated.connectedPeerIds, {'ORBIT-CCCCCC'});
  });
}
