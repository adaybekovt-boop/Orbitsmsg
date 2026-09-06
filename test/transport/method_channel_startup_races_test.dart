import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/plugin_orbits_transport.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_transport/orbits_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('early events arriving before subscription are buffered and drained in order', () async {
    const channel = MethodChannel('app.orbits/transport');
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        return {'noisePublicKey': '01' * 32, 'backend': 'hyperswarm'};
      }
      return <String, Object?>{};
    });
    addTearDown(() => binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    final previous = OrbitsTransportPlatform.instance;
    final platform = MethodChannelOrbitsTransport(channel: channel);
    OrbitsTransportPlatform.instance = platform;
    addTearDown(() => OrbitsTransportPlatform.instance = previous);

    // Send 3 platform events BEFORE any stream listener is attached
    for (var i = 1; i <= 3; i++) {
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        'app.orbits/transport',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('event', {
            'name': 'connected',
            'peerId': 'ORBIT-PEER-$i',
          }),
        ),
        (_) {},
      );
    }

    // Now instantiate PluginOrbitsTransport and listen
    final transport = PluginOrbitsTransport(backend: 'hyperswarm');
    final events = <TransportEvent>[];
    final sub = transport.events.listen(events.add);
    addTearDown(sub.cancel);

    await Future<void>.delayed(Duration.zero);

    // All 3 early events must be drained in FIFO order
    expect(events.length, 3);
    expect((events[0] as TransportConnected).peerId, 'ORBIT-PEER-1');
    expect((events[1] as TransportConnected).peerId, 'ORBIT-PEER-2');
    expect((events[2] as TransportConnected).peerId, 'ORBIT-PEER-3');

    await transport.stop();
  });

  test('late events arriving after stop do not throw into closed controller', () async {
    const channel = MethodChannel('app.orbits/transport');
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async => <String, Object?>{});
    addTearDown(() => binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    final previous = OrbitsTransportPlatform.instance;
    final platform = MethodChannelOrbitsTransport(channel: channel);
    OrbitsTransportPlatform.instance = platform;
    addTearDown(() => OrbitsTransportPlatform.instance = previous);

    final transport = PluginOrbitsTransport(backend: 'hyperswarm');
    final sub = transport.events.listen((_) {});
    addTearDown(sub.cancel);

    await transport.stop();

    // Emitting an event now should be safely ignored and NOT crash
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'app.orbits/transport',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('event', {
          'name': 'connected',
          'peerId': 'ORBIT-LATE',
        }),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  });
}
