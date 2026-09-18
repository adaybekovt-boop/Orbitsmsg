// Liquid-glass appearance prefs from the React settings surface.
// Persisted locally — never faked as a network/theme catalog change.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kReduceTransparencyPrefKey = 'orbits_reduce_transparency';
const String kGlassStrengthPrefKey = 'orbits_glass_strength';

class AppearancePrefs {
  const AppearancePrefs({
    this.reduceTransparency = false,
    this.glassStrength = 65,
  });

  final bool reduceTransparency;

  /// 0–100, same scale as the React slider (default 65).
  final int glassStrength;

  AppearancePrefs copyWith({bool? reduceTransparency, int? glassStrength}) {
    return AppearancePrefs(
      reduceTransparency: reduceTransparency ?? this.reduceTransparency,
      glassStrength: glassStrength ?? this.glassStrength,
    );
  }
}

class AppearancePrefsNotifier extends StateNotifier<AppearancePrefs> {
  AppearancePrefsNotifier() : super(const AppearancePrefs()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final reduce = prefs.getString(kReduceTransparencyPrefKey) == '1';
      final strength = prefs.getInt(kGlassStrengthPrefKey) ?? 65;
      if (mounted) {
        state = AppearancePrefs(
          reduceTransparency: reduce,
          glassStrength: strength.clamp(0, 100),
        );
      }
    } catch (_) {}
  }

  Future<void> setReduceTransparency(bool value) async {
    state = state.copyWith(reduceTransparency: value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kReduceTransparencyPrefKey, value ? '1' : '0');
    } catch (_) {}
  }

  Future<void> setGlassStrength(int value) async {
    state = state.copyWith(glassStrength: value.clamp(0, 100));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(kGlassStrengthPrefKey, state.glassStrength);
    } catch (_) {}
  }
}

final appearancePrefsProvider =
    StateNotifierProvider<AppearancePrefsNotifier, AppearancePrefs>(
      (ref) => AppearancePrefsNotifier(),
    );

/// Maps the React 0–100 slider onto the theme blur sigma.
double orbitsGlassBlurForStrength(double baseSigma, int strength) {
  final t = strength.clamp(0, 100) / 100.0;
  return baseSigma * (0.55 + 0.7 * t);
}

/// Slightly denser film as intensity rises; never fully opaque here.
Color orbitsGlassTintForStrength(Color base, int strength) {
  final t = strength.clamp(0, 100) / 100.0;
  final a = (base.a * (0.75 + 0.5 * t)).clamp(0.0, 1.0);
  return base.withValues(alpha: a);
}
