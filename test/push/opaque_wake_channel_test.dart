import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/push/opaque_wake_channel.dart';
import 'package:orbits_flutter/push/wake_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('OS wake channel forwards only a safe opaque payload', () async {
    final wake = OpaqueWakeService();
    final hop = OpaqueWakeChannel(onWake: (payload) => wake.handle(payload));
    hop.attach();
    addTearDown(hop.detach);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      kOpaqueWakeChannelName,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('opaqueWake', {
          'opaqueWakeToken': 'tok',
          'collapseId': 'c',
          'protocolVersion': 1,
          'peerId': 'ORBIT-AAAAAAAAAAAAAAAA',
        }),
      ),
      (_) {},
    );
    expect(wake.lastAccepted, isNull);
    expect(wake.rejected, 0);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      kOpaqueWakeChannelName,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('opaqueWake', {
          'opaqueWakeToken': 'tok',
          'collapseId': 'c',
          'protocolVersion': 1,
        }),
      ),
      (_) {},
    );
    expect(wake.lastAccepted?.opaqueWakeToken, 'tok');
    expect(wake.lastAccepted?.collapseId, 'c');
  });
}
