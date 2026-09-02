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
    expect(early, contains('remoteUnderstandsNativeCall'));
    expect(early, contains('takeNative'));
    expect(early, contains('Нет активного P2P-соединения'));

    final startOutgoing = startFn.indexOf('startOutgoing');
    final callPeer = startFn.indexOf('.callPeer');
    expect(startOutgoing, greaterThan(startFn.indexOf('takeNative')));
    expect(callPeer, greaterThan(startOutgoing));
    expect(
      startFn.indexOf('return;', startOutgoing),
      lessThan(callPeer),
      reason: 'native call-v1 path must return before PeerJS .callPeer',
    );

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
      bool remoteUnderstandsNativeCall = false,
    }) {
      final peerjsOk = peerjsAllowedOnNativeFor(mode, isWeb: isWeb);
      final takeNative = canUseNative && remoteUnderstandsNativeCall;
      return (!peerjsOk || !leftoverPeer) && !takeNative;
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
      isTrue,
    );
    expect(
      failClosedBeforeMedia(
        mode: kPeerjsIsolationWebOnly,
        isWeb: false,
        leftoverPeer: true,
        canUseNative: true,
        remoteUnderstandsNativeCall: true,
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
        .split('Future<void> toggleScreenShare(')[0];
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
    expect(accept, contains('conn.close'));
    final acceptNative = accept.indexOf('_nativeSession!.accept');
    expect(acceptNative, greaterThan(0));
    expect(
      accept.indexOf('return;', acceptNative),
      lessThan(accept.indexOf('conn?.answer')),
      reason: 'native answer must return before PeerJS answer',
    );

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
    expect(attach, contains('remoteUnderstandsNativeCall'));
    expect(
      attach.indexOf('remoteUnderstandsNativeCall'),
      lessThan(attach.indexOf('_conn = conn')),
      reason: 'call-v1 remotes must not attach leftover PeerJS media',
    );

    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test(
      'toggleScreenShare isolation gate sits before getUserMedia and getDisplayMedia',
      () {
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);

    final src = File('lib/state/calls_provider.dart').readAsStringSync();
    expect(src, isNot(contains('peerjsAllowedOnNative()')));

    final share = src
        .split('Future<void> toggleScreenShare(')[1]
        .split('Future<void> hangUp(')[0];
    expect(share, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(share, isNot(contains('peerjsAllowedOnNative()')));
    final gateIdx = share.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    expect(gateIdx, greaterThanOrEqualTo(0));
    expect(
      share.indexOf('navigator.mediaDevices.getUserMedia'),
      greaterThan(gateIdx),
    );
    expect(share.indexOf('getDisplayMedia'), greaterThan(gateIdx));
    expect(share, contains('_nativeMedia'));
    expect(share, contains('_publishNativeMediaState'));

    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test('setMicEnabled and setVideoEnabled publish native mediaState', () {
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);

    final src = File('lib/state/calls_provider.dart').readAsStringSync();
    final mic = src
        .split('void setMicEnabled(')[1]
        .split('void setVideoEnabled(')[0];
    expect(mic, contains('_publishNativeMediaState'));
    final video = src
        .split('void setVideoEnabled(')[1]
        .split('Future<void> toggleScreenShare(')[0];
    expect(video, contains('_publishNativeMediaState'));
    expect(src, contains('session.publishMediaState'));
    expect(src, contains('CallSignalType.mediaState'));
    expect(src, contains('remoteMicEnabled'));
    final replace = src
        .split('Future<void> _replaceVideoTrack(')[1]
        .split('void _attachConnection(')[0];
    expect(
      replace.indexOf('_nativeMedia?.peerConnection'),
      lessThan(replace.indexOf('_conn?.peerConnection')),
    );

    final nativeSignal = src
        .split('void _onNativeCallSignal(')[1]
        .split('void _bindToCurrentPeer(')[0];
    expect(nativeSignal, contains('signal.isRoomVoice'));
    expect(
      nativeSignal.indexOf('signal.isRoomVoice'),
      lessThan(nativeSignal.indexOf('NativeCallSession')),
    );

    final onCall = src
        .split('_callSub = current.onCall.listen')[1]
        .split('void dispose()')[0];
    expect(onCall, contains('remoteUnderstandsNativeCall'));
    expect(
      onCall.indexOf('remoteUnderstandsNativeCall'),
      lessThan(onCall.indexOf('_attachConnection')),
      reason: 'inbound PeerJS from a call-v1 peer must close before attach',
    );

    expect(
      File('lib/ui/calls/call_overlay_mount.dart').readAsStringSync(),
      contains('remoteMicEnabled'),
    );
    expect(
      File('lib/ui/calls/call_overlay_mount.dart').readAsStringSync(),
      contains('remoteScreenSharing'),
    );

    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });
}
