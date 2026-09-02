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
    expect(wake, contains('OrbitsPushBridge.emitWake'));
    expect(
      File('android/app/src/main/kotlin/com/orbits/orbits_flutter/MainActivity.kt')
          .readAsStringSync(),
      contains('OrbitsPushBridge.attach'),
    );
    expect(
      File(
        'android/app/src/main/kotlin/com/orbits/orbits_flutter/OrbitsPushBridge.kt',
      ).existsSync(),
      isTrue,
    );

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

    const forbiddenPins = <String>[
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
      'text',
      'body',
      'title',
      'senderName',
      'displayName',
      'peerId',
      'conversationId',
      'attachment',
      'mime',
      'fileName',
    ];
    for (final key in forbiddenPins) {
      expect(ios, contains('"$key"'),
          reason: 'iOS wake host missing forbidden key $key');
      expect(wake, contains('"$key"'),
          reason: 'Android wake host missing forbidden key $key');
    }
    expect(ios, contains('fileKey'));
    expect(ios, contains('discoverySecret'));
    expect(ios, contains('vaultKek'));
    expect(ios, contains('nested'));
    expect(ios, contains('NSDictionary'));
    expect(ios, contains('ObjectIdentifier'));
    expect(wake, contains('fileKey'));
    expect(wake, contains('discoverySecret'));
    expect(wake, contains('vaultKek'));
    expect(wake, contains('nested'));
    expect(wake, contains('Bundle'));
    expect(wake, contains('identityHashCode'));
    expect(ios, contains('OpaqueWake'));
    expect(wake, contains('OpaqueWake'));
    expect(ios, contains('kForbiddenReplicationFields'));
    expect(wake, contains('kForbiddenReplicationFields'));

    final iosWakeStart = ios.indexOf('didReceiveRemoteNotification');
    expect(iosWakeStart, greaterThanOrEqualTo(0));
    final iosWakeEnd =
        ios.indexOf('@objc private func batteryDidChange', iosWakeStart);
    expect(iosWakeEnd, greaterThan(iosWakeStart));
    final iosWake = ios.substring(iosWakeStart, iosWakeEnd);
    expect(iosWake, isNot(contains('http://')));
    expect(iosWake, isNot(contains('https://')));
    expect(wake, isNot(contains('http://')));
    expect(wake, isNot(contains('https://')));

    expect(ios, contains('tokenIsSafe'));
    expect(wake, contains('tokenIsSafe'));
    expect(ios, contains('://'));
    expect(wake, contains('://'));
    expect(ios, contains('contains("rootKey")'),
        reason: 'iOS tokenIsSafe must reject rootKey as a token fragment');
    expect(wake, contains('contains("rootKey")'),
        reason: 'Android tokenIsSafe must reject rootKey as a token fragment');
    expect(iosWake, contains('"opaqueWakeToken"'));
    expect(iosWake, contains('"collapseId"'));
    expect(iosWake, contains('"protocolVersion"'));
    expect(iosWake, isNot(contains('arguments: userInfo')));

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
    expect(scope, contains("'token'"));
    expect(scope, contains('acceptPushToken'));
    expect(
      File('lib/transport/native_transport_host.dart').readAsStringSync(),
      contains('acceptPushToken'),
    );
    expect(
      File('lib/transport/native_transport_host.dart').readAsStringSync(),
      contains('Device tokens stay on-device'),
    );
    expect(
      File('lib/transport/native_transport_host_stub.dart').readAsStringSync(),
      contains('onLowBattery'),
    );
    expect(
      File('lib/transport/native_transport_host_stub.dart').readAsStringSync(),
      contains('acceptPushToken'),
    );
    expect(
      File('lib/push/push_send.dart').readAsStringSync(),
      contains('apns-not-deployed'),
    );
    expect(
      File('lib/push/apns_provider_jwt.dart').existsSync(),
      isTrue,
    );
    expect(
      File('lib/push/apns_provider_jwt.dart').readAsStringSync(),
      contains('Not identity-signing-v1'),
    );
  });
}
