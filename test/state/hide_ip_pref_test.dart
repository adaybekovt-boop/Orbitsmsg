// R05 — "hide my IP" is a user preference, not RELAY_ONLY dart-define,
// and relay-only without TURN must refuse the connection.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/signaling.dart';
import 'package:orbits_flutter/state/hide_ip_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('user pref overlay + persist survives a "restart"', () async {
    SharedPreferences.setMockInitialValues({});
    final n1 = HideIpNotifier();
    await n1.setEnabled(true);
    expect(n1.state, isTrue);

    // New notifier = new process / Settings reload.
    final n2 = HideIpNotifier();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(n2.state, isTrue);

    final env = envWithUserHideIp(const PeerEnv(), n2.state);
    expect(env.relayOnly, isTrue);
    expect(
      () => buildRtcConfig(env),
      throwsA(isA<RelayOnlyUnavailable>()),
    );

    final withTurn = envWithUserHideIp(
      const PeerEnv(
        turnUrl: 'turn:t:3478',
        turnUsername: 'u',
        turnCredential: 'c',
      ),
      true,
    );
    expect(buildRtcConfig(withTurn).iceTransportPolicy, 'relay');
  });
}
