import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_transport/orbits_transport.dart';
import 'package:orbits_transport_platform_interface/orbits_transport_platform_interface.dart';

void main() {
  test('default instance is unimplemented and IPC version is pinned', () {
    expect(kOrbitsBareIpcInfo, 'orbits-bare-ipc-v1');
    expect(
      () => OrbitsTransportPlugin().start({'peerId': 'ORBIT-AA'}),
      throwsA(isA<UnimplementedError>()),
    );
  });

  test('in-process host covers start/publish/suspend/resume/stop', () async {
    final previous = OrbitsTransportPlatform.instance;
    final host = InProcessOrbitsTransportPlatform();
    OrbitsTransportPlatform.instance = host;
    addTearDown(() => OrbitsTransportPlatform.instance = previous);
    final plugin = OrbitsTransportPlugin();
    await plugin.start({'peerId': 'ORBIT-AA', 'remoteJs': false});
    await plugin.publish({'deviceId': 'dev-a'});
    await plugin.connect({'peerId': 'ORBIT-BB'});
    await plugin.suspend();
    expect(
      () => plugin.send('ORBIT-BB', 'message', const [1]),
      throwsStateError,
    );
    await plugin.resume();
    await plugin.send('ORBIT-BB', 'message', const [1, 2, 3]);
    await plugin.stop();
    expect(host.started, isFalse);
    expect(
      host.calls,
      containsAll(['start', 'publish', 'suspend', 'resume', 'stop']),
    );
  });

  test('hosts refuse remote executable JS', () async {
    final host = InProcessOrbitsTransportPlatform();
    await expectLater(
      host.start({'peerId': 'ORBIT-AA', 'remoteJs': true}),
      throwsStateError,
    );
    await expectLater(
      host.start({
        'peerId': 'ORBIT-AA',
        'remoteJsUrl': 'https://example.invalid/worklet.js',
      }),
      throwsStateError,
    );
    expect(
      () => assertNoRemoteBareJs({'bundleUrl': 'http://127.0.0.1/evil.js'}),
      throwsStateError,
    );
    final channel = MethodChannelOrbitsTransport();
    await expectLater(channel.start({'remoteJs': true}), throwsStateError);
  });

  test('oversized IPC frames and missing file paths fail closed', () async {
    final host = InProcessOrbitsTransportPlatform();
    OrbitsTransportPlatform.instance = host;
    await host.start({'peerId': 'ORBIT-AA', 'remoteJs': false});
    await expectLater(
      host.send(
        'ORBIT-BB',
        'message',
        List<int>.filled(kOrbitsBareIpcMaxFrameBytes + 1, 1),
      ),
      throwsStateError,
    );
    await expectLater(host.sendFile('ORBIT-BB', '', 1), throwsStateError);
    await host.sendFile('ORBIT-BB', '/tmp/a.bin', 12);
    expect(host.calls, contains('sendFile'));
  });
}
