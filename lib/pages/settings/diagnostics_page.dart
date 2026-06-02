// Settings -> Diagnostics.
//
// Small operational panel for build metadata, image-cache stats, and the
// update checker. Updates are driven by [updateNotifierProvider].
//   • Phase 2: surfaces whether a newer GitHub Release exists + release notes.
//   • Phase 3 (Windows): downloads the installer with progress.
//   • Phase 4 (Windows): launches the installer (after a confirm dialog) and
//     closes the app so it can update files.
// On non-Windows / web the in-app flow is unavailable and the panel offers the
// GitHub release page instead. Downloading/installing never deletes user data —
// the installer only replaces app files.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/update_notifier.dart';
import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_button.dart';
import '../../ui/primitives/orbits_glass_surface.dart';
import '../../ui/primitives/orbs_card.dart';

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
    _packageInfoFuture = PackageInfo.fromPlatform();
    // Lightweight, NON-BLOCKING auto-check when this screen opens (after the
    // first frame). Guarded by a once-per-session cooldown in the notifier so
    // it runs at most once. Deliberately NOT wired into app startup — opening
    // Diagnostics can never slow or block app launch, and we don't make an
    // unsolicited network call on every cold start.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(updateNotifierProvider.notifier).maybeAutoCheck();
    });
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Confirm with the user, then launch the downloaded installer. On success
  /// the notifier closes the app (so the installer can replace files); on
  /// failure we keep the app open and surface the error.
  Future<void> _confirmAndInstall() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Установить обновление?'),
        content: const Text(
          'Приложение закроется, и установщик продолжит обновление. '
          'Ваши данные (чаты, контакты, профиль) сохранятся — обновляются '
          'только файлы программы.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Установить обновление'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final result =
        await ref.read(updateNotifierProvider.notifier).launchInstaller();
    if (!mounted) return;
    if (!result.launched) {
      // Use the calm Russian message the notifier set on state (never the raw
      // technical service message). The panel also shows it inline.
      final message = ref.read(updateNotifierProvider).installError ??
          'Не удалось запустить установщик.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
    // On success the app is exiting; nothing more to do here.
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final update = ref.watch(updateNotifierProvider);
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
                    update: update,
                    fallbackVersion: info?.version,
                    installSupported: ref.watch(installSupportedProvider),
                    onCheck: () =>
                        ref.read(updateNotifierProvider.notifier).check(),
                    onDownload: () => ref
                        .read(updateNotifierProvider.notifier)
                        .downloadUpdate(),
                    onInstall: _confirmAndInstall,
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
    required this.update,
    required this.fallbackVersion,
    required this.installSupported,
    required this.onCheck,
    required this.onDownload,
    required this.onInstall,
    required this.onOpenUrl,
  });

  final UpdateState update;
  final String? fallbackVersion;
  final bool installSupported;
  final VoidCallback onCheck;
  final VoidCallback onDownload;
  final VoidCallback onInstall;
  final Future<void> Function(String url) onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final checking = update.isChecking;
    final statusColor = switch (update.status) {
      UpdateUiStatus.failed => tokens.danger,
      UpdateUiStatus.updateAvailable => tokens.accent,
      UpdateUiStatus.latestUnusable => tokens.muted,
      _ => tokens.muted,
    };

    final currentVersion = update.currentVersion ?? fallbackVersion;
    final notes = update.releaseNotes?.trim();

    return OrbitsGlassSurface(
      role: OrbitsGlassRole.card,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OrbsSettingRow(
            label: 'Проверить обновления',
            subtitle: _statusText(update),
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
          if (update.hasChecked) ...[
            const OrbsDivider(),
            OrbsSettingRow(
              label: 'Текущая версия',
              subtitle: (currentVersion == null || currentVersion.isEmpty)
                  ? 'Неизвестно'
                  : currentVersion,
            ),
            const OrbsDivider(),
            OrbsSettingRow(
              label: 'Последняя версия',
              subtitle: (update.latestVersion == null ||
                      update.latestVersion!.isEmpty)
                  ? 'Неизвестно'
                  : update.latestVersion!,
            ),
            if (update.checkedAt != null) ...[
              const OrbsDivider(),
              OrbsSettingRow(
                label: 'Последняя проверка',
                subtitle: _formatCheckedAt(update.checkedAt!),
              ),
            ],
            if (update.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                update.errorMessage!,
                style: TextStyle(
                  color: statusColor,
                  fontFamily: tokens.fontBody,
                  fontSize: 12,
                ),
              ),
            ],
            if (update.updateAvailable && notes != null && notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Что нового',
                style: TextStyle(
                  color: tokens.text,
                  fontFamily: tokens.fontHeading,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _notesSummary(notes),
                style: TextStyle(
                  color: tokens.muted,
                  fontFamily: tokens.fontBody,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
            if (update.updateAvailable) ...[
              const SizedBox(height: 12),
              if (installSupported)
                ..._buildWindowsFlow(context, tokens)
              else
                ..._buildReleasePageOnly(tokens),
            ],
          ],
        ],
      ),
    );
  }

  // ── Windows in-app download + install flow (Phases 3–4) ───────────────
  List<Widget> _buildWindowsFlow(BuildContext context, OrbitsTokens tokens) {
    final children = <Widget>[];

    switch (update.downloadStatus) {
      case DownloadUiStatus.idle:
        children.add(OrbitsGlassButton(
          label: 'Скачать обновление',
          icon: Icons.download_outlined,
          variant: OrbitsGlassVariant.primary,
          onPressed: onDownload,
        ));

      case DownloadUiStatus.downloading:
        children.addAll(_downloadingRows(tokens));

      case DownloadUiStatus.downloaded:
        children.addAll(_downloadedRows(context, tokens));

      case DownloadUiStatus.failed:
        children.add(Text(
          update.downloadError ?? 'Не удалось скачать обновление.',
          style: TextStyle(
            color: tokens.danger,
            fontFamily: tokens.fontBody,
            fontSize: 12,
          ),
        ));
        children.add(const SizedBox(height: 8));
        children.add(OrbitsGlassButton(
          label: 'Скачать заново',
          icon: Icons.refresh,
          onPressed: onDownload,
        ));

      case DownloadUiStatus.unsupported:
        children.addAll(_buildReleasePageOnly(tokens));
        return children;
    }

    // Always offer the release page as a secondary, manual fallback.
    children.add(const SizedBox(height: 8));
    children.add(OrbitsGlassButton(
      label: 'Открыть страницу релиза',
      icon: Icons.open_in_new,
      variant: OrbitsGlassVariant.secondary,
      onPressed: update.releaseUrl == null
          ? null
          : () => onOpenUrl(update.releaseUrl!),
    ));
    return children;
  }

  List<Widget> _downloadingRows(OrbitsTokens tokens) {
    final progress = update.downloadProgress; // 0..1 or null
    final received = _formatMb(update.downloadReceived);
    final total =
        update.downloadTotal != null ? _formatMb(update.downloadTotal!) : null;
    final label = total != null
        ? 'Скачивание… $received / $total МБ'
        : 'Скачивание… $received МБ';
    return [
      Text(
        label,
        style: TextStyle(
          color: tokens.text,
          fontFamily: tokens.fontBody,
          fontSize: 12.5,
        ),
      ),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(
          value: progress, // null → indeterminate
          minHeight: 6,
          backgroundColor: tokens.muted.withValues(alpha: 0.2),
          valueColor: AlwaysStoppedAnimation<Color>(tokens.accent),
        ),
      ),
    ];
  }

  List<Widget> _downloadedRows(BuildContext context, OrbitsTokens tokens) {
    switch (update.installStatus) {
      case InstallUiStatus.launching:
        return [
          Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(tokens.accent),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Запуск установщика…',
                style: TextStyle(
                  color: tokens.text,
                  fontFamily: tokens.fontBody,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ];

      case InstallUiStatus.launched:
        return [
          Text(
            'Установщик запущен. Можно закрыть приложение — '
            'обновление продолжится автоматически.',
            style: TextStyle(
              color: tokens.text,
              fontFamily: tokens.fontBody,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
        ];

      case InstallUiStatus.failed:
        return [
          Text(
            update.installError ?? 'Не удалось запустить установщик.',
            style: TextStyle(
              color: tokens.danger,
              fontFamily: tokens.fontBody,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          OrbitsGlassButton(
            label: 'Скачать заново',
            icon: Icons.refresh,
            variant: OrbitsGlassVariant.secondary,
            onPressed: onDownload,
          ),
        ];

      case InstallUiStatus.unsupported:
        // The installer reported this platform can't run it. Never imply
        // install is possible — fall back to the release page.
        return _buildReleasePageOnly(tokens);

      case InstallUiStatus.idle:
      case InstallUiStatus.readyToInstall:
        return [
          Text(
            'Обновление скачано',
            style: TextStyle(
              color: tokens.text,
              fontFamily: tokens.fontHeading,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          OrbitsGlassButton(
            label: 'Установить обновление',
            icon: Icons.system_update_alt,
            variant: OrbitsGlassVariant.primary,
            onPressed: onInstall,
          ),
        ];
    }
  }

  List<Widget> _buildReleasePageOnly(OrbitsTokens tokens) {
    return [
      OrbitsGlassButton(
        label: 'Открыть страницу релиза',
        icon: Icons.open_in_new,
        variant: OrbitsGlassVariant.secondary,
        onPressed: update.releaseUrl == null
            ? null
            : () => onOpenUrl(update.releaseUrl!),
      ),
      const SizedBox(height: 8),
      Text(
        'Автоматическая установка доступна в версии для Windows. '
        'На этом устройстве скачайте файл вручную со страницы релиза.',
        style: TextStyle(
          color: tokens.muted,
          fontFamily: tokens.fontBody,
          fontSize: 11.5,
          height: 1.4,
        ),
      ),
    ];
  }

  String _formatMb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);

  String _statusText(UpdateState update) {
    switch (update.status) {
      case UpdateUiStatus.checking:
        return 'Проверяем GitHub Releases…';
      case UpdateUiStatus.unknown:
        return 'Нажми, чтобы сравнить версию с GitHub Release';
      case UpdateUiStatus.failed:
        return 'Не удалось проверить обновления';
      case UpdateUiStatus.updateAvailable:
        final tag = update.latestTag ?? update.latestVersion ?? '';
        return tag.isEmpty
            ? 'Доступна новая версия'
            : 'Доступна новая версия $tag';
      case UpdateUiStatus.latestUnusable:
        return 'Последний релиз пока недоступен для установки';
      case UpdateUiStatus.upToDate:
        return 'Установлена последняя версия';
    }
  }

  String _notesSummary(String notes) {
    const maxLen = 280;
    final oneBlock = notes.replaceAll('\r\n', '\n').trim();
    if (oneBlock.length <= maxLen) return oneBlock;
    return '${oneBlock.substring(0, maxLen).trimRight()}…';
  }

  String _formatCheckedAt(DateTime when) {
    final local = when.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)} '
        '${two(local.day)}.${two(local.month)}.${local.year}';
  }
}
