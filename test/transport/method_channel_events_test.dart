import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/plugin_orbits_transport.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_transport/orbits_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('method channel forwards Bare events into PluginOrbitsTransport', () async {
    const channel = MethodChannel('app.orbits/transport');
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    final calls = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      if (call.method == 'start') {
        return {'noisePublicKey': 'ab' * 32, 'backend': 'hyperswarm'};
      }
      return <String, Object?>{};
    });
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    final previous = OrbitsTransportPlatform.instance;
    final plugin = MethodChannelOrbitsTransport(channel: channel);
    OrbitsTransportPlatform.instance = plugin;
    addTearDown(() => OrbitsTransportPlatform.instance = previous);

    final transport = PluginOrbitsTransport(backend: 'hyperswarm');
    final events = <TransportEvent>[];
    final sub = transport.events.listen(events.add);
    addTearDown(sub.cancel);

    await transport.start(
      const TransportLocalConfiguration(peerId: 'ORBIT-AAAAAAAAAAAAAAAA'),
    );
    expect(calls, contains('start'));

    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'app.orbits/transport',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('event', {
          'name': 'connected',
          'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
        }),
      ),
      (_) {},
    );
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'app.orbits/transport',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('event', {
          'name': 'frame',
          'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
          'channel': 'message',
          'frameB64': 'cGluZw==',
        }),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(events.whereType<TransportConnected>(), isNotEmpty);
    final frame = events.whereType<TransportFrame>().single;
    expect(frame.peerId, 'ORBIT-BBBBBBBBBBBBBBBB');
    expect(String.fromCharCodes(frame.bytes), 'ping');

    await transport.connect(
      PeerDescriptor(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        noisePublicKey: 'cd' * 32,
      ),
    );
    expect(calls, contains('connect'));
    await transport.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      const [1, 2, 3],
    );
    expect(calls, contains('send'));
    await transport.publish(
      DeviceBinding(
        version: kDeviceBindingVersion,
        identityPublicKey: Uint8List.fromList(List<int>.filled(32, 2)),
        deviceId: 'dev-a',
        transportPublicKey: Uint8List.fromList(List<int>.filled(32, 3)),
        hypercorePublicKey: Uint8List.fromList(List<int>.filled(32, 4)),
        capabilities: const ['hyperswarm-v1'],
        createdAt: 1,
        expiresAt: 2,
        signatureByIdentityKey: Uint8List.fromList(List<int>.filled(64, 5)),
      ),
    );
    expect(calls, contains('publish'));
    await transport.stop();
    expect(calls, contains('stop'));
  });
}
