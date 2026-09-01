import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/bare_ipc_client.dart';
import 'package:orbits_flutter/transport/ipc_codec.dart';

void main() {
  test('in-process IPC start/suspend/resume/stop', () async {
    final pair = openInProcessIpc();
    expect(kOrbitsBareIpcInfo, 'orbits-bare-ipc-v1');
    await pair.client.request('start', {'peerId': 'ORBIT-AA'});
    expect(pair.worklet.started, isTrue);
    await pair.client.request('publish', {
      'binding': {'deviceId': 'dev-a'},
    });
    expect(pair.worklet.published, isTrue);
    await pair.client.request('suspend');
    expect(pair.worklet.suspended, isTrue);
    await expectLater(pair.client.request('send'), throwsStateError);
    await pair.client.request('resume');
    await pair.client.request('stop');
    expect(pair.worklet.started, isFalse);
    expect(pair.worklet.methods, containsAll(['start', 'suspend', 'resume', 'stop']));
    await pair.client.close();
  });
}
