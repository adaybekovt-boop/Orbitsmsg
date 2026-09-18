// Development-only Bare/Hyperswarm test path.
//
// Off in release builds even if the dart-define is present. Production
// rollout stays HyperswarmRollout.off. Enabling this path never falls
// back to PeerJS.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kDevBareTransportPrefKey = 'orbits_dev_bare_transport';
const bool kDevBareTransportDartDefine = bool.fromEnvironment(
  'ORBITS_DEV_BARE_TRANSPORT',
);

bool _devBarePrefEnabled = false;

/// In-memory copy of the debug pref so transport gates can read it
/// without a Riverpod lookup. Release builds ignore this.
void hydrateDevBareTransportPref(bool enabled) {
  _devBarePrefEnabled = enabled;
}

void resetDevBareTransportForTests() {
  _devBarePrefEnabled = false;
}

bool isMobileBareHost({
  TargetPlatform? platform,
  bool isWeb = kIsWeb,
}) {
  if (isWeb) return false;
  final resolved = platform ?? defaultTargetPlatform;
  return resolved == TargetPlatform.android || resolved == TargetPlatform.iOS;
}

bool isDevBareTransportRequested({
  bool dartDefine = kDevBareTransportDartDefine,
  bool releaseMode = kReleaseMode,
  bool? prefEnabled,
}) {
  if (releaseMode) return false;
  return dartDefine || (prefEnabled ?? _devBarePrefEnabled);
}

class DevBareTransportNotifier extends StateNotifier<bool> {
  DevBareTransportNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    if (kReleaseMode) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final on = prefs.getString(kDevBareTransportPrefKey) == '1';
      hydrateDevBareTransportPref(on);
      if (mounted) state = on;
    } catch (_) {}
  }

  Future<void> set(bool value) async {
    if (kReleaseMode) return;
    hydrateDevBareTransportPref(value);
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kDevBareTransportPrefKey, value ? '1' : '0');
    } catch (_) {}
  }

  bool get requested => isDevBareTransportRequested(prefEnabled: state);
}

final devBareTransportProvider =
    StateNotifierProvider<DevBareTransportNotifier, bool>(
      (ref) => DevBareTransportNotifier(),
    );
