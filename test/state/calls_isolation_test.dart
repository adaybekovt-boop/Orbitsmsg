// Phase 14 leftover: CallsNotifier.startCall must fail closed on isolation
// before getUserMedia, and leftover PeerJS media connections must not attach.
// Native DualStack still proceeds when canUseNative is true.
// Product [kPeerjsIsolationMode] stays default-live.

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/peerjs_window.dart';

void main() {
  test('startCall isolation gate sits before getUserMedia and considers native',
      () {
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);

    final src = File('lib/state/calls_provider.dart').readAsStringSync();
    expect(src, isNot(contains('peerjsAllowedOnNative()')));

    final startFn = src
        .split('Future<void> startCall(')[1]
        .split('Future<void> acceptCurrent')[0];
    expect(startFn, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(startFn, isNot(contains('peerjsAllowedOnNative()')));
    final gateIdx = startFn.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    expect(gateIdx, greaterThanOrEqualTo(0));
    expect(startFn.indexOf('getUserMedia'), greaterThan(gateIdx));

    final early = startFn.substring(0, startFn.indexOf('getUserMedia'));
    expect(early, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(early, contains('canUseNative'));
    expect(early, contains('Нет активного P2P-соединения'));

    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test(
      'startCall fail-closes leftover PeerJS only when native cannot take the call',
      () {
    expect(kIsWeb, isFalse, reason: 'VM test is native, not Flutter web');
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);

    bool failClosedBeforeMedia({
      required String mode,
      required bool isWeb,
      required bool leftoverPeer,
      required bool canUseNative,
    }) {
      final peerjsOk = peerjsAllowedOnNativeFor(mode, isWeb: isWeb);
      return (!peerjsOk || !leftoverPeer) && !canUseNative;
    }

    expect(
      failClosedBeforeMedia(
        mode: kPeerjsIsolationWebOnly,
        isWeb: false,
        leftoverPeer: true,
        canUseNative: false,
      ),
      isTrue,
    );
    expect(
      failClosedBeforeMedia(
        mode: kPeerjsIsolationWebOnly,
        isWeb: false,
        leftoverPeer: true,
        canUseNative: true,
      ),
      isFalse,
    );
    expect(
      failClosedBeforeMedia(
        mode: kPeerjsIsolationRemoved,
        isWeb: false,
        leftoverPeer: true,
        canUseNative: false,
      ),
      isTrue,
    );
    expect(
      failClosedBeforeMedia(
        mode: kPeerjsIsolationDefaultLive,
        isWeb: false,
        leftoverPeer: true,
        canUseNative: false,
      ),
      isFalse,
    );
    expect(
      failClosedBeforeMedia(
        mode: kPeerjsIsolationWebOnly,
        isWeb: true,
        leftoverPeer: true,
        canUseNative: false,
      ),
      isFalse,
    );

    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test('acceptCurrent isolation gate sits before getUserMedia without native',
      () {
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);

    final src = File('lib/state/calls_provider.dart').readAsStringSync();
    final accept = src
        .split('Future<void> acceptCurrent(')[1]
        .split('Future<void> hangUp(')[0];
    expect(accept, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(accept, isNot(contains('peerjsAllowedOnNative()')));
    final gateIdx = accept.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    expect(gateIdx, greaterThanOrEqualTo(0));
    expect(
      accept.indexOf('navigator.mediaDevices.getUserMedia'),
      greaterThan(gateIdx),
    );
    expect(accept, contains('_nativeSession == null'));
    expect(accept, contains('Нет активного P2P-соединения'));

    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test(
      '_attachConnection isolation gate sits before _conn and onStream.listen',
      () {
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);

    final src = File('lib/state/calls_provider.dart').readAsStringSync();
    expect(src, isNot(contains('peerjsAllowedOnNative()')));

    final attach = src
        .split('void _attachConnection(')[1]
        .split('void _resetIdleWithError')[0];
    expect(attach, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(attach, isNot(contains('peerjsAllowedOnNative()')));
    final gateIdx = attach.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    expect(gateIdx, greaterThanOrEqualTo(0));
    expect(attach.indexOf('_conn = conn'), greaterThan(gateIdx));
    expect(attach.indexOf('onStream.listen'), greaterThan(gateIdx));
    expect(attach.indexOf('onClose.listen'), greaterThan(gateIdx));
    expect(attach, contains('conn.close'));

    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });
}
