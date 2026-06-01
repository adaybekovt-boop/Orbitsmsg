// Settings → Диагностика.
//
// Mirrors `screen === 'diagnostics'` in JS Settings: app version, build
// hash, PWA / service-worker status, image-cache stats, etc. Today
// shows what we have providers for — version + cache size — and stubs
// the rest with a "В разработке" label.

import 'package:flutter/material.dart';

import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/orbits_glass_button.dart';
import '../../ui/primitives/orbits_glass_surface.dart';
import '../../ui/primitives/orbs_card.dart';

class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final imageCache = PaintingBinding.instance.imageCache;
    final cacheBytes = imageCache.currentSizeBytes;
    final cacheMax = imageCache.maximumSizeBytes;
    final cacheCount = imageCache.currentSize;
    final cacheMaxCount = imageCache.maximumSize;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: const OrbitsGlassSurface(
          role: OrbitsGlassRole.appBar,
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
          child: SizedBox.expand(),
        ),
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
          'Диагностика',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // ── Intro ────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              'Техническая информация для проверки работы приложения.',
              style: TextStyle(
                fontSize: 13,
                color: tokens.muted,
                fontFamily: tokens.fontBody,
                height: 1.45,
              ),
            ),
          ),
          // ── Build ────────────────────────────────────────────
          const OrbsSectionTitle('Сборка'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: OrbitsGlassSurface(
              role: OrbitsGlassRole.card,
              padding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              child: Column(
                children: [
                  OrbsSettingRow(
                    label: 'Версия',
                    subtitle: 'Orbits Flutter • 0.1.0',
                  ),
                  OrbsDivider(),
                  OrbsSettingRow(
                    label: 'Платформа',
                    subtitle: 'Flutter 3.41 • Dart 3.11',
                  ),
                ],
              ),
            ),
          ),

          // ── Image cache ──────────────────────────────────────
          const OrbsSectionTitle('Кэш изображений'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: OrbitsGlassSurface(
              role: OrbitsGlassRole.card,
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              child: Column(
                children: [
                  OrbsSettingRow(
                    label: 'Память',
                    subtitle:
                        '${(cacheBytes / 1024 / 1024).toStringAsFixed(1)} / '
                        '${(cacheMax / 1024 / 1024).toStringAsFixed(0)} МБ',
                  ),
                  const OrbsDivider(),
                  OrbsSettingRow(
                    label: 'Записей',
                    subtitle: '$cacheCount / $cacheMaxCount',
                  ),
                ],
              ),
            ),
          ),

          // ── Coming soon ──────────────────────────────────────
          const OrbsSectionTitle('В разработке'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: OrbitsGlassSurface(
              role: OrbitsGlassRole.card,
              padding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              child: Column(
                children: [
                  OrbsSettingRow(
                    label: 'Service Worker',
                    subtitle: 'PWA-кэш и оффлайн-режим',
                  ),
                  OrbsDivider(),
                  OrbsSettingRow(
                    label: 'Логи',
                    subtitle: 'Последние ошибки и предупреждения',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
