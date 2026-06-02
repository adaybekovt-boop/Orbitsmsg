// Power-saver: pure budget override + persisted toggle. Deterministic, offline.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:orbits_flutter/state/power_saver_provider.dart';
import 'package:orbits_flutter/themes/perf_budget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fullBudget = PerfBudget(
    tier: PerfTier.full,
    particles: 48,
    fpsCap: 0,
    motion: true,
    reason: 'default',
  );

  group('applyPowerSaver', () {
    test('off → budget unchanged', () {
      expect(applyPowerSaver(fullBudget, false), same(fullBudget));
    });

    test('on → forced frozen tier (no motion, no particles)', () {
      final b = applyPowerSaver(fullBudget, true);
      expect(b.tier, PerfTier.frozen);
      expect(b.motion, isFalse);
      expect(b.particles, 0);
      expect(b.fpsCap, 0);
      expect(b.reason, 'power-saver');
    });
  });

  group('PowerSaverNotifier', () {
    test('set(true) updates state and persists', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final c = ProviderContainer();
      addTearDown(c.dispose);

      await c.read(powerSaverProvider.notifier).set(true);

      expect(c.read(powerSaverProvider), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('orbits_power_saver'), '1');
    });

    test('loads a persisted "on" value on construction (survives restart)',
        () async {
      SharedPreferences.setMockInitialValues({'orbits_power_saver': '1'});
      final c = ProviderContainer();
      addTearDown(c.dispose);

      c.read(powerSaverProvider); // construct → async _load()
      for (var i = 0; i < 100 && c.read(powerSaverProvider) == false; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(c.read(powerSaverProvider), isTrue);
    });
  });
}
