// Phase 14 leftover: PeerJS packet-router Drop must fail closed when
// isolation forbids PeerJS. Native DualStack drop uses onDrop → DropBridge,
// not this router. Product [kPeerjsIsolationMode] stays default-live.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/peerjs_window.dart';

void main() {
  test(
    '_buildRouterCtx dropAllowed fail-closes when isolation forbids PeerJS',
    () {
      expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
      expect(kPeerjsSupportWindowOpen, isTrue);

      final src =
          File('lib/state/connections_notifier.dart').readAsStringSync();
      final buildRouter = src
          .split('PacketRouterCtx _buildRouterCtx')[1]
          .split('Future<void> _postReliableOpen')[0];
      final dropAllowed =
          buildRouter.split('dropAllowed:')[1].split('isBlocked:')[0];

      expect(
        dropAllowed,
        contains('peerjsAllowedOnNative(isWeb: kIsWeb)'),
      );
      expect(dropAllowed, contains('isVerified'));
      expect(dropAllowed, contains('isPeerBlocked'));
      expect(dropAllowed, isNot(contains('peerjsAllowedOnNative()')));
      expect(dropAllowed, isNot(contains('canUseNative')));

      expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
      expect(kPeerjsSupportWindowOpen, isTrue);
    },
  );
}
