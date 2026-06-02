// Auto-lock settings (Settings → Security).
//
// Drives [AutoLockScope]: when enabled, the vault re-locks (KEK cleared →
// password screen) after [idleTimeout] of no interaction, or when the app
// returns from the background after being away that long. Persisted under the
// existing `orbits_auto_lock` key ('1'/'0'), so it survives restart. No data is
// wiped — locking only clears the in-memory key.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kAutoLockPrefKey = 'orbits_auto_lock';

class AutoLockSettings {
  const AutoLockSettings({
    required this.enabled,
    this.idleTimeout = const Duration(minutes: 5),
  });

  final bool enabled;
  final Duration idleTimeout;

  AutoLockSettings copyWith({bool? enabled, Duration? idleTimeout}) =>
      AutoLockSettings(
        enabled: enabled ?? this.enabled,
        idleTimeout: idleTimeout ?? this.idleTimeout,
      );
}

class AutoLockNotifier extends StateNotifier<AutoLockSettings> {
  AutoLockNotifier({Duration idleTimeout = const Duration(minutes: 5)})
      : super(AutoLockSettings(enabled: false, idleTimeout: idleTimeout)) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getString(kAutoLockPrefKey) == '1';
      if (mounted) state = state.copyWith(enabled: enabled);
    } catch (_) {
      // Default (disabled) stands on any read failure.
    }
  }

  Future<void> setEnabled(bool value) async {
    state = state.copyWith(enabled: value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kAutoLockPrefKey, value ? '1' : '0');
    } catch (_) {
      // Non-fatal: the in-memory state is already updated for this session.
    }
  }
}

final autoLockProvider =
    StateNotifierProvider<AutoLockNotifier, AutoLockSettings>(
  (ref) => AutoLockNotifier(),
);
