import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_transport/orbits_transport.dart';

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
    expect(host.calls, containsAll(['start', 'publish', 'suspend', 'resume', 'stop']));
    expect(await plugin.barePath(), isNull);
  });

  test('federated facade maps every native OS and not the PWA', () {
    final pub = File('pubspec.yaml').readAsStringSync();
    expect(pub, contains('default_package: orbits_transport_android'));
    expect(pub, contains('default_package: orbits_transport_ios'));
    expect(pub, contains('default_package: orbits_transport_linux'));
    expect(pub, contains('default_package: orbits_transport_macos'));
    expect(pub, contains('default_package: orbits_transport_windows'));
    expect(pub, isNot(contains('orbits_transport_web')));
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
      () => assertNoRemoteBareJs({
        'bundleUrl': 'http://127.0.0.1/evil.js',
      }),
      throwsStateError,
    );
    final channel = MethodChannelOrbitsTransport();
    await expectLater(
      channel.start({'remoteJs': true}),
      throwsStateError,
    );
    expect(
      File('lib/method_channel_orbits_transport.dart').readAsStringSync(),
      contains('barePath'),
    );
    expect(
      File('lib/method_channel_orbits_transport.dart').readAsStringSync(),
      contains("startsWith('http://')"),
    );
  });
}
