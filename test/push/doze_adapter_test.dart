import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/push/doze_adapter.dart';
import 'package:orbits_flutter/push/opaque_wake.dart';
import 'package:orbits_flutter/push/wake_service.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/transport_lifecycle.dart';

void main() {
  test(
    'Doze treats the socket as mortal and reconnects on opaque wake',
    () async {
      final transport = LoopbackOrbitsTransport();
      await transport.start(
        const TransportLocalConfiguration(
          peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
          discoverySecret: [1, 2, 3],
        ),
      );
      final life = TransportLifecycle(transport: transport);
      final doze = DozeAdapter(lifecycle: life);
      expect(doze.mayHoldForegroundService, isFalse);
      await doze.enterBackground();
      expect(doze.socketAlive, isFalse);
      expect(life.suspended, isTrue);
      await doze.enterDoze();
      expect(doze.phase, OsLifecyclePhase.doze);
      expect(doze.needsReconnect, isTrue);

      final wake = OpaqueWakeService(onAccepted: (_) => doze.onOpaqueWake());
      final rejected = await wake.handle({
        'opaqueWakeToken': 'tok',
        'collapseId': 'c',
        'protocolVersion': 1,
        'peerId': 'ORBIT-AA',
      });
      expect(rejected.accepted, isFalse);
      expect(doze.phase, OsLifecyclePhase.doze);

      final ok = await wake.handle({
        'opaqueWakeToken': 'tok',
        'collapseId': 'c',
        'protocolVersion': 1,
      });
      expect(ok.accepted, isTrue);
      expect(doze.socketAlive, isTrue);
      expect(doze.reconnectAttempts, 1);
      expect(life.suspended, isFalse);
    },
  );

  test('iOS privacy manifest does not enable tracking', () {
    final text = File('ios/Runner/PrivacyInfo.xcprivacy').readAsStringSync();
    expect(text, contains('<key>NSPrivacyTracking</key>'));
    expect(text, contains('<false/>'));
    expect(text, contains('NSPrivacyTrackingDomains'));
  });
}
