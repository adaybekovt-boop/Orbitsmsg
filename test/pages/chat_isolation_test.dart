// Phase 14 leftover: ChatViewPage.initState must not queue a PeerJS
// dial when isolation forbids PeerJS, unless DualStack can take the
// peer (`canUseNative`). Product [kPeerjsIsolationMode] stays default-live.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/peerjs_window.dart';

void main() {
  test('initState isolation gate sits before openReliable and considers native',
      () {
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);

    final src = File('lib/pages/chat_view_page.dart').readAsStringSync();
    expect(src, isNot(contains("import 'dart:io'")));
    expect(src, isNot(contains('peerjsAllowedOnNative()')));

    final init = src.split('void initState()')[1].split('void dispose()')[0];
    final postFrame = init
        .split('addPostFrameCallback')[1]
        .split('_lastMarkedReadTs')[0];

    expect(postFrame, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(postFrame, isNot(contains('peerjsAllowedOnNative()')));
    expect(postFrame, contains('canUseNative'));
    expect(postFrame, contains('openReliable'));

    final gateIdx = postFrame.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    expect(gateIdx, greaterThanOrEqualTo(0));
    expect(postFrame.indexOf('openReliable'), greaterThan(gateIdx));
    expect(postFrame.indexOf('canUseNative'), greaterThan(gateIdx));

    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });
}
