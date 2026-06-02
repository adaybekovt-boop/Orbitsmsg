// Power-saver ("lite mode") toggle. When on, the performance budget is forced
// to the frozen tier (no animated backgrounds, no motion) regardless of device
// class — see perf_budget.dart's applyPowerSaver. Persisted under the existing
// `orbits_power_saver` key so it survives restart.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kPowerSaverPrefKey = 'orbits_power_saver';

class PowerSaverNotifier extends StateNotifier<bool> {
  PowerSaverNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final on = prefs.getString(kPowerSaverPrefKey) == '1';
      if (mounted) state = on;
    } catch (_) {
      // Default (off) stands on a read failure.
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kPowerSaverPrefKey, value ? '1' : '0');
    } catch (_) {
      // Non-fatal — in-memory state already updated for this session.
    }
  }
}

/// App-wide lite-mode flag. Read by the perf-budget controllers (which force the
/// frozen tier when true) and the Power-saver settings page.
final powerSaverProvider =
    StateNotifierProvider<PowerSaverNotifier, bool>((ref) => PowerSaverNotifier());
