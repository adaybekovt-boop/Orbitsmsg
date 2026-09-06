import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/signaling.dart';
import 'package:orbits_flutter/state/peer_connection_provider.dart';

void main() {
  test('app env without override is still public PeerJS', () {
    final env = resolveAppPeerEnv(const {});
    expect(isPeerjsLocalTestnet(env), isFalse);
    expect(buildSignalingHosts(env), [
      '0.peerjs.com',
      '1.peerjs.com',
      '2.peerjs.com',
    ]);
    final ep = resolveEndpoint(host: '0.peerjs.com', env: env);
    expect(ep.secure, isTrue);
    expect(ep.port, 443);
    expect(env.resolvedPeerKey, 'peerjs');
  });

  test('app env parses ORBITS_PEERJS_HOST for localhost QA', () {
    final env = resolveAppPeerEnv(const {
      kOrbitsPeerjsHostEnv: '127.0.0.1',
      kOrbitsPeerjsPortEnv: '9000',
      kOrbitsPeerjsSecureEnv: 'false',
    });
    expect(isPeerjsLocalTestnet(env), isTrue);
    expect(buildSignalingHosts(env), ['127.0.0.1']);
    expect(canRotateHosts(env, buildSignalingHosts(env)), isFalse);
    final ep = resolveEndpoint(host: '127.0.0.1', env: env);
    expect(ep.secure, isFalse);
    expect(ep.port, 9000);
  });
}
