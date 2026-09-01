import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CallKit and Telecom never take a peer id; wake extras stay opaque', () {
    final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(ios, contains('CallKit'));
    expect(ios, contains('must not receive a peer id'));
    expect(ios, contains('localizedCallerName = "Orbits"'));
    expect(ios, contains('CXProviderConfiguration()'));
    expect(ios, isNot(contains('localizedName =')));
    expect(ios, isNot(contains('voip')));

    final android =
        File('android/app/src/main/kotlin/com/orbits/orbits_flutter/MainActivity.kt')
            .readAsStringSync();
    expect(android, contains('must not receive a peer id'));
    expect(android, contains('ACTION_DEVICE_IDLE_MODE_CHANGED'));
    expect(android, contains('ACTION_BATTERY_LOW'));
    expect(android, contains('ACTION_BATTERY_OKAY'));
    expect(android, contains('"battery"'));

    expect(ios, contains('app.orbits/lifecycle'));
    expect(ios, contains('batteryStateDidChangeNotification'));
    expect(ios, contains('batteryLevelDidChangeNotification'));
    expect(ios, contains('isBatteryMonitoringEnabled'));

    final wake = File(
      'android/app/src/main/kotlin/com/orbits/orbits_flutter/OrbitsWakeReceiver.kt',
    ).readAsStringSync();
    expect(wake, contains('opaqueWakeToken'));
    expect(wake, contains('peerId'));

    final androidManifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(androidManifest, contains('FOREGROUND_SERVICE_PHONE_CALL'));
    expect(androidManifest, isNot(contains('FOREGROUND_SERVICE_DATA_SYNC')));

    final telecom = File(
      'android/app/src/main/kotlin/com/orbits/orbits_flutter/OrbitsConnectionService.kt',
    ).readAsStringSync();
    expect(telecom, contains('class OrbitsConnection : Connection()'));
    expect(telecom, isNot(contains('val conn = Connection()')));
    expect(telecom, contains('Must not be given a Peer ID'));

    expect(ios, contains('registerForRemoteNotifications'));
    expect(ios, contains('opaqueWakeToken'));
    expect(ios, contains('didReceiveRemoteNotification'));

    final phase13 = File('docs/migration/phase13-group-e2e-review.md')
        .readAsStringSync();
    expect(phase13, contains('kRoomsApplicationE2eImplemented'));
    expect(phase13, contains('false'));

    final window =
        File('docs/migration/peerjs-support-window.md').readAsStringSync();
    expect(window, contains('not started'));
    expect(window, contains('default-live'));

    final scope =
        File('lib/transport/transport_lifecycle_scope.dart').readAsStringSync();
    expect(scope, contains("'battery'"));
    expect(scope, contains('onLowBattery'));
    expect(scope, contains('onBatteryOkay'));
    expect(
      File('lib/transport/native_transport_host_stub.dart').readAsStringSync(),
      contains('onLowBattery'),
    );
  });
}
