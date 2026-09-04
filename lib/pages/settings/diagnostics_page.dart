// Settings -> Diagnostics.
//
// Small operational panel for build metadata and image-cache stats. The update
// checker now lives in its own user-facing page (Settings → Обновления); this
// screen keeps a shortcut to it so it's still discoverable from the old spot.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../transport/native_transport_host.dart';

import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_button.dart';
import '../../ui/primitives/orbits_glass_app_bar.dart';
import '../../ui/primitives/orbits_glass_surface.dart';
import '../../ui/primitives/orbs_card.dart';
import 'updates_page.dart';

class DiagnosticsPage extends ConsumerStatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  ConsumerState<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends ConsumerState<DiagnosticsPage> {
  late final Future<PackageInfo> _packageInfoFuture;

  @override
  void initState() {
    super.initState();
    _packageInfoFuture = PackageInfo.fromPlatform().timeout(
      const Duration(seconds: 3),
      onTimeout: () => PackageInfo(
        appName: 'Orbits',
        packageName: 'com.orbits.orbits_flutter',
        version: 'unknown',
        buildNumber: '0',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final imageCache = PaintingBinding.instance.imageCache;
    final cacheBytes = imageCache.currentSizeBytes;
    final cacheMax = imageCache.maximumSizeBytes;
    final cacheCount = imageCache.currentSize;
    final cacheMaxCount = imageCache.maximumSize;

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
          'Диагностика',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
      ),
      body: AdaptivePageFrame(
        maxWidth: 760,
        child: FutureBuilder<PackageInfo>(
          future: _packageInfoFuture,
          builder: (context, snapshot) {
            final info = snapshot.data;
            final versionText = info == null
                ? 'Загрузка...'
                : '${info.version}+${info.buildNumber}';
            return ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
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
                const OrbsSectionTitle('Транспорт'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: OrbitsGlassSurface(
                    role: OrbitsGlassRole.card,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: OrbsSettingRow(
                      label: 'Канал',
                      subtitle: ref
                          .watch(nativeTransportHostProvider)
                          .visibleTransportLabel,
                    ),
                  ),
                ),
                const OrbsSectionTitle('Сборка'),
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
                          label: 'Версия',
                          subtitle: 'Orbits • $versionText',
                        ),
                        const OrbsDivider(),
                        const OrbsSettingRow(
                          label: 'Платформа',
                          subtitle: 'Flutter stable',
                        ),
                      ],
                    ),
                  ),
                ),
                const OrbsSectionTitle('Обновления'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: OrbitsGlassSurface(
                    role: OrbitsGlassRole.card,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: OrbsSettingRow(
                      label: 'Проверить обновления',
                      subtitle: 'Открыть раздел «Обновления»',
                      trailing: Icon(Icons.chevron_right, color: tokens.muted),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const UpdatesPage(),
                        ),
                      ),
                    ),
                  ),
                ),
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
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    );
  }
}
