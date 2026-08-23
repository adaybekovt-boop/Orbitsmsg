// Runtime TURN credentials. Compile-time `--dart-define=TURN_USERNAME` /
// `TURN_CREDENTIAL` bake secrets into every APK/EXE/web bundle (CI logs
// too). Production loads username/credential from SharedPreferences;
// `TURN_URL` may still be a dart-define (it is not a secret).
//
// Local/dev escape hatch: `--dart-define=ALLOW_COMPILE_TIME_TURN_SECRETS=true`.

import 'package:shared_preferences/shared_preferences.dart';

import 'signaling.dart';

const String kTurnUsernamePref = 'orbits_turn_username';
const String kTurnCredentialPref = 'orbits_turn_credential';

class TurnRuntimeCreds {
  const TurnRuntimeCreds({this.username, this.credential});

  final String? username;
  final String? credential;

  bool get hasUsername => username != null && username!.isNotEmpty;
  bool get hasCredential => credential != null && credential!.isNotEmpty;
}

/// Compile-time TURN username/credential. Empty or disallowed → null.
String? compileTimeTurnSecret(
  String raw, {
  required bool allowCompileTimeSecrets,
}) {
  if (!allowCompileTimeSecrets) return null;
  final t = raw.trim();
  return t.isEmpty ? null : t;
}

String? _nonEmpty(String? value) {
  if (value == null) return null;
  final t = value.trim();
  return t.isEmpty ? null : t;
}

Future<TurnRuntimeCreds> loadTurnRuntimeCreds() async {
  final prefs = await SharedPreferences.getInstance();
  return TurnRuntimeCreds(
    username: _nonEmpty(prefs.getString(kTurnUsernamePref)),
    credential: _nonEmpty(prefs.getString(kTurnCredentialPref)),
  );
}

Future<void> saveTurnRuntimeCreds({
  required String username,
  required String credential,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(kTurnUsernamePref, username);
  await prefs.setString(kTurnCredentialPref, credential);
}

/// Runtime username/credential win when present; otherwise keep [env].
PeerEnv applyTurnRuntime(PeerEnv env, TurnRuntimeCreds creds) {
  return env.copyWith(
    turnUsername: creds.username ?? env.turnUsername,
    turnCredential: creds.credential ?? env.turnCredential,
  );
}
