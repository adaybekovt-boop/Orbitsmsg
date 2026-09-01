import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CallKit and Telecom never take a peer id; wake extras stay opaque', () {
    final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(ios, contains('CallKit'));
    expect(ios, contains('must not receive a peer id'));
    expect(ios, contains('localizedCallerName = "Orbits"'));
    expect(ios, isNot(contains('voip')));

    final android =
        File('android/app/src/main/kotlin/com/orbits/orbits_flutter/MainActivity.kt')
            .readAsStringSync();
    expect(android, contains('must not receive a peer id'));

    final wake = File(
      'android/app/src/main/kotlin/com/orbits/orbits_flutter/OrbitsWakeReceiver.kt',
    ).readAsStringSync();
    expect(wake, contains('opaqueWakeToken'));
    expect(wake, contains('peerId'));

    final phase13 = File('docs/migration/phase13-group-e2e-review.md')
        .readAsStringSync();
    expect(phase13, contains('kRoomsApplicationE2eImplemented'));
    expect(phase13, contains('false'));

    final window =
        File('docs/migration/peerjs-support-window.md').readAsStringSync();
    expect(window, contains('not started'));
    expect(window, contains('default-live'));
  });
}
