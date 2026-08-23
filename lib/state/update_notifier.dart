// Update-check state layer (in-app update flow).
//
// Riverpod wrapper around the [UpdateChecker] (parses the latest GitHub
// Release), the Windows installer [UpdateDownloader], and the [UpdateInstaller]
// launcher. Check / download / install are kept as separate, understandable
// state machines.
//
// Testable + offline + web-safe: the HTTP client (via [updateCheckerProvider]),
// the installed-version reader (via [installedVersionReaderProvider]), the
// downloader, installer, app-exit hook, and the "install supported" flag are all
// overridable. The download/install services use conditional imports, so this
// file never pulls in `dart:io` and stays importable from the web build.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/installed_version.dart';
import '../core/update_checker.dart';
import '../core/update_downloader.dart';
import '../core/update_installer.dart';

/// Shown when Authenticode verification fails. A.1 is not fully closed
/// (no production SHA-256 thumbprint / signtool secret yet), so Install
/// must say why it stopped instead of looking hung.
const String kUpdateSignatureUntrustedMessage =
    'Не удалось проверить подпись обновления, установка отменена';

/// UI-facing status of the latest update check.
enum UpdateUiStatus {
  /// Not checked yet this session.
  unknown,

  /// A check is in flight.
  checking,

  /// Installed version is current (or newer). No update.
  upToDate,

  /// A newer, usable release exists.
  updateAvailable,

  /// The check failed (network / HTTP / malformed).
  failed,
}

/// State of the installer download (Windows only).
enum DownloadUiStatus {
  /// Nothing downloaded / not started.
  idle,

  /// Bytes are streaming in.
  downloading,

  /// The installer file is saved and verified.
  downloaded,

  /// The download failed (HTTP / size / IO).
  failed,

  /// This platform can't download an installer (web / non-Windows).
  unsupported,
}

/// State of the installer launch (Windows only).
enum InstallUiStatus {
  /// No installer ready / not started.
  idle,

  /// A verified installer is on disk and can be launched.
  readyToInstall,

  /// The installer process is being started.
  launching,

  /// The installer was started; the app may now close.
  launched,

  /// Launching the installer failed.
  failed,

  /// This platform can't run the installer (web / non-Windows).
  unsupported,
}

/// Immutable snapshot the Settings/Updates UI renders.
class UpdateState {
  const UpdateState({
    this.status = UpdateUiStatus.unknown,
    this.currentVersion,
    this.latestVersion,
    this.latestTag,
    this.updateAvailable = false,
    this.releaseUrl,
    this.windowsAssetUrl,
    this.androidAssetUrl,
    this.checkedAt,
    this.errorMessage,
    this.downloadStatus = DownloadUiStatus.idle,
    this.downloadReceived = 0,
    this.downloadTotal,
    this.installerPath,
    this.downloadError,
    this.installStatus = InstallUiStatus.idle,
    this.installError,
  });

  final UpdateUiStatus status;
  final String? currentVersion;
  final String? latestVersion;
  final String? latestTag;
  final bool updateAvailable;
  final String? releaseUrl;

  /// Direct download URL of the `orbits-windows-x64.exe` asset, if the latest
  /// release ships one.
  final String? windowsAssetUrl;

  /// Direct download URL of the preferred Android APK asset, if any.
  final String? androidAssetUrl;
  final DateTime? checkedAt;
  final String? errorMessage;

  // ── Download (Windows) ─────────────────────────────────────────────
  final DownloadUiStatus downloadStatus;
  final int downloadReceived;
  final int? downloadTotal;

  /// Absolute path to the verified installer once [downloadStatus] is
  /// [DownloadUiStatus.downloaded].
  final String? installerPath;
  final String? downloadError;

  // ── Install (Windows) ──────────────────────────────────────────────
  final InstallUiStatus installStatus;
  final String? installError;

  bool get isChecking => status == UpdateUiStatus.checking;

  /// True once at least one check has completed (success or failure).
  bool get hasChecked =>
      status != UpdateUiStatus.unknown && status != UpdateUiStatus.checking;

  /// Whether the latest release ships a Windows installer we could download.
  bool get hasWindowsInstaller =>
      windowsAssetUrl != null && windowsAssetUrl!.isNotEmpty;

  bool get isDownloading => downloadStatus == DownloadUiStatus.downloading;

  /// Download progress in 0..1, or null when the total size is unknown.
  double? get downloadProgress {
    final total = downloadTotal;
    if (total == null || total <= 0) return null;
    final p = downloadReceived / total;
    return p.clamp(0.0, 1.0);
  }

  bool get isInstallerReady =>
      installStatus == InstallUiStatus.readyToInstall && installerPath != null;

  UpdateState copyWith({
    UpdateUiStatus? status,
    Object? currentVersion = _unset,
    Object? latestVersion = _unset,
    Object? latestTag = _unset,
    bool? updateAvailable,
    Object? releaseUrl = _unset,
    Object? windowsAssetUrl = _unset,
    Object? androidAssetUrl = _unset,
    Object? checkedAt = _unset,
    Object? errorMessage = _unset,
    DownloadUiStatus? downloadStatus,
    int? downloadReceived,
    Object? downloadTotal = _unset,
    Object? installerPath = _unset,
    Object? downloadError = _unset,
    InstallUiStatus? installStatus,
    Object? installError = _unset,
  }) {
    return UpdateState(
      status: status ?? this.status,
      currentVersion: identical(currentVersion, _unset)
          ? this.currentVersion
          : currentVersion as String?,
      latestVersion: identical(latestVersion, _unset)
          ? this.latestVersion
          : latestVersion as String?,
      latestTag:
          identical(latestTag, _unset) ? this.latestTag : latestTag as String?,
      updateAvailable: updateAvailable ?? this.updateAvailable,
      releaseUrl: identical(releaseUrl, _unset)
          ? this.releaseUrl
          : releaseUrl as String?,
      windowsAssetUrl: identical(windowsAssetUrl, _unset)
          ? this.windowsAssetUrl
          : windowsAssetUrl as String?,
      androidAssetUrl: identical(androidAssetUrl, _unset)
          ? this.androidAssetUrl
          : androidAssetUrl as String?,
      checkedAt:
          identical(checkedAt, _unset) ? this.checkedAt : checkedAt as DateTime?,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
      downloadStatus: downloadStatus ?? this.downloadStatus,
      downloadReceived: downloadReceived ?? this.downloadReceived,
      downloadTotal: identical(downloadTotal, _unset)
          ? this.downloadTotal
          : downloadTotal as int?,
      installerPath: identical(installerPath, _unset)
          ? this.installerPath
          : installerPath as String?,
      downloadError: identical(downloadError, _unset)
          ? this.downloadError
          : downloadError as String?,
      installStatus: installStatus ?? this.installStatus,
      installError: identical(installError, _unset)
          ? this.installError
          : installError as String?,
    );
  }
}

const Object _unset = Object();

class UpdateNotifier extends StateNotifier<UpdateState> {
  UpdateNotifier({
    required UpdateChecker checker,
    required Future<String> Function() readVersion,
    required UpdateDownloader downloader,
    required UpdateInstaller installer,
    required Future<void> Function() appExit,
    required bool installSupported,
  })  : _checker = checker,
        _readVersion = readVersion,
        _downloader = downloader,
        _installer = installer,
        _appExit = appExit,
        _installSupported = installSupported,
        super(const UpdateState());

  final UpdateChecker _checker;
  final Future<String> Function() _readVersion;
  final UpdateDownloader _downloader;
  final UpdateInstaller _installer;
  final Future<void> Function() _appExit;

  /// Whether THIS platform can download + run a Windows installer. False on
  /// web / Android / macOS / Linux, where the UI offers the release page only.
  final bool _installSupported;

  bool get installSupported => _installSupported;

  /// Manual, user-initiated check. Sets [UpdateUiStatus.checking] synchronously,
  /// then resolves to a result/failure. Never throws (the checker swallows
  /// transport errors into an error result).
  Future<void> check() async {
    if (state.isChecking) return;
    state = state.copyWith(
      status: UpdateUiStatus.checking,
      errorMessage: null,
    );

    String current;
    try {
      current = await _readVersion();
    } catch (_) {
      current = '';
    }

    final result = await _checker.check(currentVersion: current);
    if (!mounted) return;
    state = _stateFromResult(result, fallbackCurrent: current);
  }

  /// Lightweight auto-check with a once-per-session cooldown: runs only if no
  /// check has happened yet this session (status is still `unknown`). Safe to
  /// call from a screen's post-frame callback — it never blocks and is a no-op
  /// on subsequent calls.
  Future<void> maybeAutoCheck() async {
    if (state.status != UpdateUiStatus.unknown) return;
    await check();
  }

  /// Download the Windows installer for the available update to a private temp
  /// file, reporting progress. No-op if already downloading. This only fetches
  /// the asset; it never overwrites the running app or touches the install dir.
  /// User data (DB / secure storage / profile) is never touched.
  Future<void> downloadUpdate() async {
    if (state.isDownloading) return;

    if (!_installSupported) {
      state = state.copyWith(
        downloadStatus: DownloadUiStatus.unsupported,
        installStatus: InstallUiStatus.unsupported,
      );
      return;
    }

    final url = state.windowsAssetUrl;
    if (url == null || url.isEmpty) {
      state = state.copyWith(
        downloadStatus: DownloadUiStatus.failed,
        downloadError: 'Для этой версии нет установщика Windows. '
            'Откройте страницу релиза, чтобы скачать вручную.',
      );
      return;
    }

    state = state.copyWith(
      downloadStatus: DownloadUiStatus.downloading,
      downloadReceived: 0,
      downloadTotal: null,
      downloadError: null,
      installStatus: InstallUiStatus.idle,
      installError: null,
      installerPath: null,
    );

    final result = await _downloader.download(
      url,
      fileName: kWindowsInstallerFileName,
      // The latest-release API we parse doesn't expose the asset size, so we
      // don't pre-verify length; the HTTP Content-Length drives the progress
      // bar and the downloader still rejects an empty/zero-byte file.
      expectedSize: null,
      onProgress: (received, total) {
        if (!mounted) return;
        state = state.copyWith(
          downloadReceived: received,
          downloadTotal: total,
        );
      },
    );
    if (!mounted) return;

    switch (result.status) {
      case DownloadStatus.downloaded:
        state = state.copyWith(
          downloadStatus: DownloadUiStatus.downloaded,
          downloadReceived: result.bytes ?? state.downloadReceived,
          installerPath: result.filePath,
          installStatus: InstallUiStatus.readyToInstall,
          downloadError: null,
        );
      case DownloadStatus.unsupportedPlatform:
        state = state.copyWith(
          downloadStatus: DownloadUiStatus.unsupported,
          installStatus: InstallUiStatus.unsupported,
        );
      default:
        state = state.copyWith(
          downloadStatus: DownloadUiStatus.failed,
          downloadError: _downloadErrorText(result.status),
        );
    }
  }

  /// Calm, honest Russian copy for a failed download. We deliberately do NOT
  /// surface the raw (often English/technical) service message to the user.
  static String _downloadErrorText(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.httpError:
        return 'Не удалось скачать файл. Проверьте интернет и попробуйте ещё раз.';
      case DownloadStatus.sizeMismatch:
        return 'Файл скачался не полностью. Попробуйте ещё раз.';
      case DownloadStatus.invalidFile:
        return 'Скачанный файл повреждён. Попробуйте ещё раз.';
      case DownloadStatus.tooLarge:
        return 'Файл слишком большой. Скачайте обновление со страницы релиза.';
      case DownloadStatus.timeout:
        return 'Скачивание заняло слишком много времени. Попробуйте ещё раз.';
      case DownloadStatus.downloaded:
      case DownloadStatus.unsupportedPlatform:
      case DownloadStatus.error:
        return 'Не удалось скачать обновление. Попробуйте ещё раз.';
    }
  }

  /// Launch the downloaded installer and, if it starts, close the app so the
  /// installer can replace files. Caller is responsible for the confirmation
  /// dialog; this performs the launch+exit. Returns the launch result so the UI
  /// can react (e.g. keep the app open on failure).
  ///
  /// The installer updates app files only — it never deletes the Drift DB,
  /// secure storage, contacts/messages, profile, rooms, or keys.
  Future<InstallLaunchResult> launchInstaller() async {
    final path = state.installerPath;
    if (path == null) {
      const result = InstallLaunchResult(
        InstallLaunchStatus.fileMissing,
        message: 'Установщик ещё не скачан. Сначала скачайте обновление.',
      );
      state = state.copyWith(
        installStatus: InstallUiStatus.failed,
        installError: result.message,
      );
      return result;
    }

    if (state.installStatus == InstallUiStatus.launching) {
      // Already in flight — return a benign error rather than double-launching.
      return const InstallLaunchResult(InstallLaunchStatus.error,
          message: 'Installer launch already in progress.');
    }

    state = state.copyWith(
      installStatus: InstallUiStatus.launching,
      installError: null,
    );

    final result = await _installer.launch(path);
    if (!mounted) return result;

    if (result.launched) {
      state = state.copyWith(installStatus: InstallUiStatus.launched);
      // Close the app AFTER the installer has started so it can update files.
      await _appExit();
      return result;
    }

    if (result.status == InstallLaunchStatus.unsupportedPlatform) {
      state = state.copyWith(installStatus: InstallUiStatus.unsupported);
    } else if (result.status == InstallLaunchStatus.signatureUntrusted) {
      state = state.copyWith(
        installStatus: InstallUiStatus.failed,
        installError: kUpdateSignatureUntrustedMessage,
      );
    } else {
      state = state.copyWith(
        installStatus: InstallUiStatus.failed,
        installError:
            'Не удалось запустить установщик. Попробуйте скачать обновление заново.',
      );
    }
    return result;
  }

  UpdateState _stateFromResult(
    UpdateCheckResult r, {
    required String fallbackCurrent,
  }) {
    final uiStatus = r.hasError
        ? UpdateUiStatus.failed
        : (r.isUpdateAvailable
            ? UpdateUiStatus.updateAvailable
            : UpdateUiStatus.upToDate);

    String? current = r.currentVersion.isNotEmpty ? r.currentVersion : null;
    current ??= fallbackCurrent.isNotEmpty ? fallbackCurrent : null;

    return UpdateState(
      status: uiStatus,
      currentVersion: current,
      latestVersion: r.latestVersion.isEmpty ? null : r.latestVersion,
      latestTag: r.latestTag.isEmpty ? null : r.latestTag,
      updateAvailable: r.isUpdateAvailable,
      releaseUrl: r.releaseUrl,
      windowsAssetUrl: r.windowsAssetUrl,
      androidAssetUrl: r.preferredAndroidAssetUrl,
      checkedAt: DateTime.now(),
      errorMessage: r.errorMessage,
    );
  }
}

/// The update checker. Overridable in tests with an injected `http.Client`.
final updateCheckerProvider = Provider<UpdateChecker>((ref) => UpdateChecker());

/// Reads the installed app version (package_info_plus). Overridable in tests so
/// no platform channel is touched.
final installedVersionReaderProvider =
    Provider<Future<String> Function()>((ref) => readInstalledVersion);

/// Installer downloader. Web-safe via conditional import; overridable in tests
/// with an injected client + temp dir.
final updateDownloaderProvider =
    Provider<UpdateDownloader>((ref) => createUpdateDownloader());

/// Installer launcher. Web-safe via conditional import; overridable in tests
/// with a recording launcher.
final updateInstallerProvider =
    Provider<UpdateInstaller>((ref) => createUpdateInstaller());

/// App-exit hook. Overridable in tests so the launch flow never kills the test
/// runner. Defaults to the platform-appropriate [requestAppExit].
final appExitProvider =
    Provider<Future<void> Function()>((ref) => requestAppExit);

/// Whether this platform supports the in-app download+install flow. True only
/// on a real Windows desktop build. Everywhere else (web / Android / macOS /
/// Linux) the UI falls back to opening the GitHub release page. Overridable in
/// tests to exercise both branches.
final installSupportedProvider = Provider<bool>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows,
);

/// App-wide update state. Survives for the container lifetime, so the
/// once-per-session cooldown in [UpdateNotifier.maybeAutoCheck] holds.
final updateNotifierProvider =
    StateNotifierProvider<UpdateNotifier, UpdateState>((ref) {
  return UpdateNotifier(
    checker: ref.watch(updateCheckerProvider),
    readVersion: ref.watch(installedVersionReaderProvider),
    downloader: ref.watch(updateDownloaderProvider),
    installer: ref.watch(updateInstallerProvider),
    appExit: ref.watch(appExitProvider),
    installSupported: ref.watch(installSupportedProvider),
  );
});
