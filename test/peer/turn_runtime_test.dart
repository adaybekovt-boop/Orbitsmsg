// Phase 3.4: compile-time TURN secrets ignored by default; runtime merge.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/signaling.dart';
import 'package:orbits_flutter/peer/turn_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('compileTimeTurnSecret', () {
    test('ignores compile-time secrets unless explicitly allowed', () {
      expect(
        compileTimeTurnSecret('leaked', allowCompileTimeSecrets: false),
        isNull,
      );
      expect(
        compileTimeTurnSecret('  leaked  ', allowCompileTimeSecrets: true),
        'leaked',
      );
      expect(
        compileTimeTurnSecret('   ', allowCompileTimeSecrets: true),
        isNull,
      );
    });
  });

  group('applyTurnRuntime', () {
    test('runtime username/credential overlay a compile-time URL', () {
      const env = PeerEnv(turnUrl: 'turn:turn.example:3478');
      final merged = applyTurnRuntime(
        env,
        const TurnRuntimeCreds(username: 'u', credential: 'c'),
      );
      final cfg = buildRtcConfig(merged);
      final turn = cfg.iceServers.firstWhere(
        (s) => (s['urls'] as String).startsWith('turn:'),
      );
      expect(turn['username'], 'u');
      expect(turn['credential'], 'c');
    });

    test('empty runtime leaves compile-time env unchanged', () {
      const env = PeerEnv(
        turnUrl: 'turn:t:3478',
        turnUsername: 'baked',
        turnCredential: 'also-baked',
      );
      final merged = applyTurnRuntime(env, const TurnRuntimeCreds());
      expect(merged.turnUsername, 'baked');
      expect(merged.turnCredential, 'also-baked');
    });
  });

  group('SharedPreferences store', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('load after save returns trimmed creds', () async {
      await saveTurnRuntimeCreds(username: ' alice ', credential: ' s3cret ');
      final loaded = await loadTurnRuntimeCreds();
      expect(loaded.username, 'alice');
      expect(loaded.credential, 's3cret');
    });

    test('empty prefs yield no creds', () async {
      final loaded = await loadTurnRuntimeCreds();
      expect(loaded.username, isNull);
      expect(loaded.credential, isNull);
    });
  });
}
