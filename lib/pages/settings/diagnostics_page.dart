// Settings -> Diagnostics.
//
// Small operational panel for build metadata, image-cache stats, and the
// manual update checker. Updates are intentionally opt-in: the app checks the
// latest GitHub Release and opens the release/asset URL in the system browser.

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/update_checker.dart';
import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_button.dart';
import '../../ui/primitives/orbits_glass_app_bar.dart';
import '../../ui/primitives/orbits_glass_surface.dart';
import '../../ui/primitives/orbs_card.dart';

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  late final Future<PackageInfo> _packageInfoFuture;
  final UpdateChecker _updateChecker = UpdateChecker();
  UpdateCheckResult? _updateResult;
  bool _checkingUpdates = false;

  @override
  void initState() {
    super.initState();
    _packageInfoFuture = PackageInfo.fromPlatform();
  }

  Future<void> _checkUpdates() async {
    if (_checkingUpdates) return;
    setState(() => _checkingUpdates = true);
    try {
      final info = await _packageInfoFuture;
      final result = await _updateChecker.check(currentVersion: info.version);
      if (!mounted) return;
      setState(() => _updateResult = result);
    } finally {
      if (mounted) setState(() => _checkingUpdates = false);
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
                          subtitle: 'TK Messenger • $versionText',
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
                  child: _UpdatePanel(
                    result: _updateResult,
                    checking: _checkingUpdates,
                    onCheck: _checkUpdates,
                    onOpenUrl: _openUrl,
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

class _UpdatePanel extends StatelessWidget {
  const _UpdatePanel({
    required this.result,
    required this.checking,
    required this.onCheck,
    required this.onOpenUrl,
  });

  final UpdateCheckResult? result;
  final bool checking;
  final VoidCallback onCheck;
  final Future<void> Function(String url) onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final result = this.result;
    final status = _statusText(result);
    final statusColor = result == null
        ? tokens.muted
        : result.hasError
            ? tokens.danger
            : result.isUpdateAvailable
                ? tokens.accent
                : tokens.muted;

    return OrbitsGlassSurface(
      role: OrbitsGlassRole.card,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OrbsSettingRow(
            label: 'Проверить обновления',
            subtitle: status,
            trailing: checking
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(tokens.accent),
                    ),
                  )
                : OrbitsGlassButton(
                    label: 'Проверить',
                    icon: Icons.system_update_alt,
                    size: OrbitsGlassSize.small,
                    variant: OrbitsGlassVariant.secondary,
                    onPressed: onCheck,
                  ),
          ),
          if (result != null) ...[
            const OrbsDivider(),
            OrbsSettingRow(
              label: 'Текущая версия',
              subtitle: result.currentVersion.isEmpty
                  ? 'Неизвестно'
                  : result.currentVersion,
            ),
            const OrbsDivider(),
            OrbsSettingRow(
              label: 'Последняя версия',
              subtitle: result.latestVersion.isEmpty
                  ? 'Неизвестно'
                  : result.latestVersion,
            ),
            if (result.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                result.errorMessage!,
                style: TextStyle(
                  color: statusColor,
                  fontFamily: tokens.fontBody,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 12),
            _UpdateActions(result: result, onOpenUrl: onOpenUrl),
          ],
        ],
      ),
    );
  }

  String _statusText(UpdateCheckResult? result) {
    if (checking) return 'Проверяем GitHub Releases...';
    if (result == null) return 'Нажми, чтобы сравнить версию с GitHub Release';
    if (result.hasError) return 'Не удалось проверить обновления';
    if (result.isUpdateAvailable) {
      return 'Доступна новая версия ${result.latestTag}';
    }
    return 'Установлена актуальная версия';
  }
}

class _UpdateActions extends StatelessWidget {
  const _UpdateActions({
    required this.result,
    required this.onOpenUrl,
  });

  final UpdateCheckResult result;
  final Future<void> Function(String url) onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final primaryAsset = _platformAssetUrl(result);
    final primaryLabel = _platformAssetLabel();
    final buttons = <Widget>[];
    if (result.isUpdateAvailable && primaryAsset != null) {
      buttons.add(
        OrbitsGlassButton(
          label: primaryLabel,
          icon: Icons.download_outlined,
          variant: OrbitsGlassVariant.primary,
          onPressed: () => onOpenUrl(primaryAsset),
        ),
      );
    }
    buttons.add(
      OrbitsGlassButton(
        label: 'Открыть релиз',
        icon: Icons.open_in_new,
        variant: OrbitsGlassVariant.secondary,
        onPressed: () => onOpenUrl(result.releaseUrl),
      ),
    );

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: buttons,
    );
  }

  String? _platformAssetUrl(UpdateCheckResult result) {
    if (kIsWeb) return null;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return result.windowsAssetUrl;
      case TargetPlatform.android:
        return result.preferredAndroidAssetUrl;
      default:
        return null;
    }
  }

  String _platformAssetLabel() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'Скачать APK';
    }
    return 'Скачать EXE';
  }
}
