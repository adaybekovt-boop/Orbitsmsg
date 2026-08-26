// Settings -> Обновления.
//
// The user-facing update panel (no longer buried in Diagnostics). Shows the
// installed version, the latest GitHub Release, and the check status, and lets
// the user check manually. On Windows it downloads the installer with progress
// and launches it (the installer updates the app — we never overwrite the
// running .exe). Everywhere else it opens the release / platform-asset link.
//
// A lightweight auto-check runs once when the page opens (post-frame, never
// blocking) via [UpdateNotifier.maybeAutoCheck].

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/authenticode.dart';
import '../../state/update_notifier.dart';
import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_app_bar.dart';
import '../../ui/primitives/orbits_glass_button.dart';
import '../../ui/primitives/orbits_glass_dialog.dart';
import '../../ui/primitives/orbits_glass_surface.dart';
import '../../ui/primitives/orbs_card.dart';

class UpdatesPage extends ConsumerStatefulWidget {
  const UpdatesPage({super.key});

  @override
  ConsumerState<UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends ConsumerState<UpdatesPage> {
  @override
  void initState() {
    super.initState();
    // Non-blocking, once-per-session auto-check the moment the page opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(updateNotifierProvider.notifier).maybeAutoCheck();
    });
  }

  Future<void> _openUrl(String? url) async {
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _confirmAndInstall() async {
    final ok = await showOrbitsConfirm(
      context: context,
      title: 'Установить обновление?',
      message: 'Приложение закроется, запустится установщик и обновит Orbits. '
          'Ваши чаты, контакты и ключи останутся на месте.',
      confirmLabel: 'Установить',
      confirmIcon: Icons.system_update_alt,
    );
    if (!ok) return;
    await ref.read(updateNotifierProvider.notifier).launchInstaller();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final state = ref.watch(updateNotifierProvider);
    final installSupported = ref.watch(installSupportedProvider);

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
          'Обновления',
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                'Orbits проверяет последнюю версию на GitHub. Обновление '
                'устанавливается только по вашему действию.',
                style: TextStyle(
                  fontSize: 13,
                  color: tokens.muted,
                  fontFamily: tokens.fontBody,
                  height: 1.45,
                ),
              ),
            ),
            const OrbsSectionTitle('Версия'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _StatusCard(
                state: state,
                onCheck: () =>
                    ref.read(updateNotifierProvider.notifier).check(),
              ),
            ),
            if (state.updateAvailable) ...[
              const OrbsSectionTitle('Действия'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: OrbitsGlassSurface(
                  role: OrbitsGlassRole.card,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  child: installSupported &&
                          !isAuthenticodePinProvisioned()
                      ? _AutoUpdateUnavailableActions(
                          onOpenLatest: () =>
                              _openUrl(kLatestWindowsInstallerUrl),
                          onOpenRelease: () => _openUrl(state.releaseUrl),
                        )
                      : installSupported
                          ? _WindowsUpdateActions(
                              state: state,
                              onDownload: () => ref
                                  .read(updateNotifierProvider.notifier)
                                  .downloadUpdate(),
                              onInstall: _confirmAndInstall,
                              onOpenRelease: () =>
                                  _openUrl(state.releaseUrl),
                            )
                          : _OpenLinkActions(
                              state: state,
                              onOpenUrl: _openUrl,
                            ),
                ),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// Current/latest version + status + the manual "Проверить" control.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state, required this.onCheck});

  final UpdateState state;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final statusColor = switch (state.status) {
      UpdateUiStatus.failed => tokens.danger,
      UpdateUiStatus.updateAvailable => tokens.accent,
      _ => tokens.muted,
    };

    return OrbitsGlassSurface(
      role: OrbitsGlassRole.card,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OrbsSettingRow(
            label: 'Проверить обновления',
            subtitle: _statusText(state),
            trailing: state.isChecking
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
                    icon: Icons.refresh,
                    size: OrbitsGlassSize.small,
                    variant: OrbitsGlassVariant.secondary,
                    onPressed: onCheck,
                  ),
          ),
          const OrbsDivider(),
          OrbsSettingRow(
            label: 'Текущая версия',
            subtitle: state.currentVersion ?? 'Неизвестно',
          ),
          const OrbsDivider(),
          OrbsSettingRow(
            label: 'Последняя версия',
            subtitle: state.latestVersion ?? 'Неизвестно',
          ),
          if (state.errorMessage != null && state.status == UpdateUiStatus.failed)
            ...[
            const SizedBox(height: 8),
            Text(
              'Не удалось проверить обновления. Проверьте интернет и '
              'попробуйте ещё раз.',
              style: TextStyle(
                color: statusColor,
                fontFamily: tokens.fontBody,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _statusText(UpdateState state) {
    switch (state.status) {
      case UpdateUiStatus.unknown:
        return 'Нажмите, чтобы сравнить версию с GitHub Release';
      case UpdateUiStatus.checking:
        return 'Проверяем GitHub Releases…';
      case UpdateUiStatus.failed:
        return 'Не удалось проверить обновления';
      case UpdateUiStatus.upToDate:
        return 'Установлена актуальная версия';
      case UpdateUiStatus.updateAvailable:
        return 'Доступна новая версия ${state.latestTag ?? state.latestVersion ?? ''}';
    }
  }
}

/// Empty Authenticode pin: do not offer Install (it always fail-closes).
class _AutoUpdateUnavailableActions extends StatelessWidget {
  const _AutoUpdateUnavailableActions({
    required this.onOpenLatest,
    required this.onOpenRelease,
  });

  final VoidCallback onOpenLatest;
  final VoidCallback onOpenRelease;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          kUpdateAutoUpdateUnavailableMessage,
          key: const Key('auto-update-unavailable'),
          style: TextStyle(
            color: tokens.danger,
            fontSize: 13,
            height: 1.4,
            fontFamily: tokens.fontBody,
          ),
        ),
        const SizedBox(height: 12),
        OrbitsGlassButton(
          label: 'Скачать с GitHub Releases',
          icon: Icons.download_outlined,
          variant: OrbitsGlassVariant.primary,
          expand: true,
          onPressed: onOpenLatest,
        ),
        const SizedBox(height: 8),
        OrbitsGlassButton(
          label: 'Открыть страницу релиза',
          icon: Icons.open_in_new,
          variant: OrbitsGlassVariant.subtle,
          expand: true,
          onPressed: onOpenRelease,
        ),
      ],
    );
  }
}

/// Windows-only: download the installer with progress, then launch it.
class _WindowsUpdateActions extends StatelessWidget {
  const _WindowsUpdateActions({
    required this.state,
    required this.onDownload,
    required this.onInstall,
    required this.onOpenRelease,
  });

  final UpdateState state;
  final VoidCallback onDownload;
  final VoidCallback onInstall;
  final VoidCallback onOpenRelease;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);

    // Downloaded + ready → offer install.
    if (state.isInstallerReady) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Обновление скачано. Установщик запустится и обновит приложение — '
            'оно закроется на это время.',
            style: TextStyle(
              color: tokens.muted,
              fontSize: 12.5,
              height: 1.4,
              fontFamily: tokens.fontBody,
            ),
          ),
          const SizedBox(height: 12),
          OrbitsGlassButton(
            label: 'Установить и перезапустить',
            icon: Icons.system_update_alt,
            variant: OrbitsGlassVariant.primary,
            expand: true,
            onPressed: onInstall,
          ),
          if (state.installError != null) ...[
            const SizedBox(height: 8),
            Text(
              state.installError!,
              style: TextStyle(
                  color: tokens.danger, fontSize: 12, fontFamily: tokens.fontBody),
            ),
          ],
        ],
      );
    }

    // Downloading → progress bar.
    if (state.isDownloading) {
      final pct = state.downloadProgress;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            pct == null
                ? 'Скачивание установщика…'
                : 'Скачивание установщика… ${(pct * 100).round()}%',
            style: TextStyle(
              color: tokens.text,
              fontSize: 13,
              fontFamily: tokens.fontBody,
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 8,
              backgroundColor: tokens.muted.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(tokens.accent),
            ),
          ),
        ],
      );
    }

    // Idle or failed → offer download (+ open release as a fallback).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.downloadError != null) ...[
          Text(
            state.downloadError!,
            style: TextStyle(
                color: tokens.danger, fontSize: 12.5, fontFamily: tokens.fontBody),
          ),
          const SizedBox(height: 10),
        ],
        if (state.installError != null) ...[
          Text(
            state.installError!,
            style: TextStyle(
                color: tokens.danger, fontSize: 12.5, fontFamily: tokens.fontBody),
          ),
          const SizedBox(height: 10),
        ],
        OrbitsGlassButton(
          label: 'Скачать обновление',
          icon: Icons.download_outlined,
          variant: OrbitsGlassVariant.primary,
          expand: true,
          onPressed: onDownload,
        ),
        const SizedBox(height: 8),
        OrbitsGlassButton(
          label: 'Открыть страницу релиза',
          icon: Icons.open_in_new,
          variant: OrbitsGlassVariant.subtle,
          expand: true,
          onPressed: onOpenRelease,
        ),
      ],
    );
  }
}

/// Non-Windows (web / Android / macOS / Linux): open the release page or the
/// platform asset link — we never try to run an installer here.
class _OpenLinkActions extends StatelessWidget {
  const _OpenLinkActions({required this.state, required this.onOpenUrl});

  final UpdateState state;
  final Future<void> Function(String? url) onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final android = state.androidAssetUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (android != null && android.isNotEmpty) ...[
          OrbitsGlassButton(
            label: 'Скачать APK',
            icon: Icons.download_outlined,
            variant: OrbitsGlassVariant.primary,
            expand: true,
            onPressed: () => onOpenUrl(android),
          ),
          const SizedBox(height: 8),
        ],
        OrbitsGlassButton(
          label: 'Открыть страницу релиза',
          icon: Icons.open_in_new,
          variant: android != null && android.isNotEmpty
              ? OrbitsGlassVariant.subtle
              : OrbitsGlassVariant.primary,
          expand: true,
          onPressed: () => onOpenUrl(state.releaseUrl),
        ),
      ],
    );
  }
}
