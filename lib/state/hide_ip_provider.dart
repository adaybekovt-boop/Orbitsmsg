// User-controlled "hide my IP" (relay-only ICE). Stored in SharedPreferences
// and applied to every PeerEnv at connection start — not the compile-time
// RELAY_ONLY dart-define.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../peer/helpers.dart';
import '../peer/signaling.dart';

class HideIpNotifier extends StateNotifier<bool> {
  HideIpNotifier() : super(false) {
    _hydrate();
  }

  Future<void> _hydrate() async {
    try {
      state = await isRelayOnlyEnabled();
    } catch (_) {}
  }

  Future<void> setEnabled(bool value) async {
    await setRelayOnlyEnabled(value);
    if (!mounted) return;
    state = value;
  }
}

final hideIpProvider =
    StateNotifierProvider<HideIpNotifier, bool>((ref) => HideIpNotifier());

/// Apply the live user preference onto a compile-time [PeerEnv].
PeerEnv envWithUserHideIp(PeerEnv env, bool hideIp) =>
    applyUserRelayOnly(env, hideIp);
