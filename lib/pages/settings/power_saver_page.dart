// Settings → Энергосбережение.
//
// Single big toggle: lite-mode on/off. When on, the performance budget is
// forced to the frozen tier via `powerSaverProvider` → perf_budget.dart, so
// atmospheric backgrounds stop animating, blur/motion are dropped, and particle
// counts go to zero. The value persists (orbits_power_saver) and re-applies on
// restart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/power_saver_provider.dart';
import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/orbits_glass_button.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_app_bar.dart';
import '../../ui/primitives/orbits_glass_surface.dart';
import '../../ui/primitives/orbits_glass_switch.dart';
import '../../ui/primitives/orbs_card.dart';

class PowerSaverPage extends ConsumerWidget {
  const PowerSaverPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = OrbitsTokens.of(context);
    final powerSaver = ref.watch(powerSaverProvider);
    return Scaffold(
      appBar: OrbitsGlassAppBar(
        leading: Navigator.of(context).canPop()
            ? Center(
                child: OrbitsGlassIconButton(
                  icon: Icons.arrow_back,
                  tooltip: 'Назад',
                  variant: OrbitsGlassVariant.subtle,
                  size: OrbitsGlassSize.small,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              )
            : null,
        title: Text(
          'Энергосбережение',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
      ),
      body: AdaptivePageFrame(
        maxWidth: 760,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            const OrbsSectionTitle('Лёгкий режим'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: OrbitsGlassSurface(
                role: OrbitsGlassRole.card,
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Включён',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              fontFamily: tokens.fontHeading,
                              color: tokens.text,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Останавливает анимированный фон и эффекты, экономит '
                            'заряд батареи.',
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.3,
                              fontFamily: tokens.fontBody,
                              color: tokens.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    OrbitsGlassSwitch(
                      value: powerSaver,
                      onChanged: (v) =>
                          ref.read(powerSaverProvider.notifier).set(v),
                      semanticLabel: 'Лёгкий режим',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.battery_saver, size: 16, color: tokens.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Полезно на слабых телефонах или при низком заряде. '
                      'Когда выключен — анимированные темы (Sakura, Graphite) '
                      'работают на полную.',
                      style: TextStyle(
                        fontSize: 12,
                        color: tokens.muted,
                        fontFamily: tokens.fontBody,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
