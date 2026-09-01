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

    final wake = OpaqueWakeService(onAccepted: (_) => life.onOpaqueWake());
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
    expect(drained, 1);
    expect(life.lastDrained, 2);
  });
}
