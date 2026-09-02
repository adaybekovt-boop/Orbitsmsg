import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/push/wake_service.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/transport_lifecycle.dart';

void main() {
  test('background suspends; opaque wake resumes and drains', () async {
    final transport = LoopbackOrbitsTransport();
    var drained = 0;
    final life = TransportLifecycle(
      transport: transport,
      onResumeDrain: () async {
        drained += 1;
        return 2;
      },
    );
    await transport.start(
      const TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: [1, 2, 3],
      ),
    );
    await life.onDoze();
    expect(life.suspended, isTrue);
    expect(life.dozing, isTrue);
    await life.onForeground();
    expect(life.suspended, isTrue);
    expect(AndroidDozePolicy.keepMessagingSocketAlive, isFalse);
    expect(AndroidDozePolicy.foregroundServiceForMessaging, isFalse);
    expect(AndroidDozePolicy.reconnectOnResume, isTrue);

    final wake = OpaqueWakeService(onAccepted: (_) => life.onOpaqueWake());
    final fromDoze = await wake.handle({
      'opaqueWakeToken': 'tok',
      'collapseId': 'c',
      'protocolVersion': 1,
    });
    expect(fromDoze.accepted, isTrue);
    expect(life.dozing, isFalse);
    expect(life.suspended, isFalse);
    expect(drained, 1);

    await life.onBackground();
    expect(life.suspended, isTrue);
    await expectLater(
      transport.send(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportChannel.message,
        const [1],
      ),
      throwsStateError,
    );

    final bad = await wake.handle({
      'opaqueWakeToken': 'tok',
      'collapseId': 'c',
      'protocolVersion': 1,
      'peerId': 'ORBIT-AA',
    });
    expect(bad.accepted, isFalse);
    expect(life.suspended, isTrue);

    final ok = await wake.handle({
      'opaqueWakeToken': 'tok',
      'collapseId': 'c',
      'protocolVersion': 1,
    });
    expect(ok.accepted, isTrue);
    expect(life.suspended, isFalse);
    expect(drained, 2);
    expect(life.lastDrained, 2);

    await life.onBackground();
    final fromString = await wake.handle({
      'opaqueWakeToken': 'tok',
      'collapseId': 'c',
      'protocolVersion': '1',
    });
    expect(fromString.accepted, isTrue);
    expect(life.suspended, isFalse);
  });

  test('low battery suspends; battery-okay does not resume native', () async {
    final transport = LoopbackOrbitsTransport();
    final life = TransportLifecycle(transport: transport);
    await transport.start(
      const TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: [1, 2, 3],
      ),
    );
    await life.onLowBattery();
    expect(life.lowBattery, isTrue);
    expect(life.suspended, isTrue);
    await expectLater(
      transport.send(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportChannel.message,
        const [1],
      ),
      throwsStateError,
    );
    await life.onForeground();
    expect(life.suspended, isTrue);
    await life.onBatteryOkay();
    expect(life.lowBattery, isFalse);
    expect(life.suspended, isTrue);
  });

  test('Doze exit resumes when battery is fine', () async {
    final transport = LoopbackOrbitsTransport();
    final life = TransportLifecycle(transport: transport);
    await transport.start(
      const TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: [1, 2, 3],
      ),
    );
    await life.onDoze();
    expect(life.dozing, isTrue);
    await life.onDozeExit();
    expect(life.dozing, isFalse);
    expect(life.suspended, isFalse);
  });
}
