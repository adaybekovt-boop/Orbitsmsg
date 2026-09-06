import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/plugin_orbits_transport.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_transport/orbits_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'app PluginOrbitsTransport crosses the federated plugin and events return',
    () async {
      final previous = OrbitsTransportPlatform.instance;
      final host = InProcessOrbitsTransportPlatform();
      OrbitsTransportPlatform.instance = host;
      addTearDown(() => OrbitsTransportPlatform.instance = previous);

      final transport = PluginOrbitsTransport(backend: 'loopback');
      final events = <TransportEvent>[];
      final sub = transport.events.listen(events.add);
      addTearDown(sub.cancel);

      await transport.start(
        const TransportLocalConfiguration(peerId: 'ORBIT-AAAAAAAAAAAAAAAA'),
      );
      expect(host.started, isTrue);
      expect(host.calls, contains('start'));

      await transport.connect(
        const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<TransportConnected>(), isNotEmpty);
      expect(
        events.whereType<TransportConnected>().single.peerId,
        'ORBIT-BBBBBBBBBBBBBBBB',
      );

      await transport.send(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportChannel.message,
        const [1, 2, 3],
      );
      expect(host.calls, contains('send'));
      await transport.stop();
    },
  );

  test('method channel start fails closed when Bare is missing', () async {
    const channel = MethodChannel('app.orbits/transport');
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'start') {
        throw PlatformException(
          code: 'BARE_RUNTIME_MISSING',
          message: 'linked Bare runtime is not shipped',
        );
      }
      return null;
    });
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final plugin = MethodChannelOrbitsTransport(channel: channel);
    await expectLater(
      plugin.start({'peerId': 'ORBIT-AA', 'remoteJs': false}),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'BARE_RUNTIME_MISSING',
        ),
      ),
    );
  });

  test(
    'in-process adapter is the only host that may start without Bare',
    () async {
      final host = InProcessOrbitsTransportPlatform();
      await host.start({'peerId': 'ORBIT-AA', 'remoteJs': false});
      expect(host.started, isTrue);
      await host.stop();
      expect(host.started, isFalse);
    },
  );
}
