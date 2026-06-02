// Update-check state layer (auto-update Phase 2).
//
// Thin Riverpod wrapper around the Phase 1 [UpdateChecker]. UI/state ONLY —
// this never downloads an asset or launches an installer. The only user action
// wired on top of this is opening the GitHub release page (handled in the UI).
//
// Testable + offline: the HTTP client (via [updateCheckerProvider]) and the
// installed-version reader (via [installedVersionReaderProvider]) are both
// overridable, so unit tests never touch package_info platform channels or the
// live GitHub API.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/update_checker.dart';

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

  /// The latest release exists but can't be offered (draft / pre-release /
  /// invalid tag).
  latestUnusable,
}

/// Immutable snapshot the Settings/Diagnostics UI renders.
class UpdateState {
  const UpdateState({
    this.status = UpdateUiStatus.unknown,
    this.currentVersion,
    this.latestVersion,
    this.latestTag,
    this.updateAvailable = false,
    this.releaseUrl,
    this.releaseNotes,
    this.assets = const <ReleaseAssetInfo>[],
    this.checkedAt,
    this.errorMessage,
  });

  final UpdateUiStatus status;
  final String? currentVersion;
  final String? latestVersion;
  final String? latestTag;
  final bool updateAvailable;
  final String? releaseUrl;
  final String? releaseNotes;
  final List<ReleaseAssetInfo> assets;
  final DateTime? checkedAt;
  final String? errorMessage;

  bool get isChecking => status == UpdateUiStatus.checking;

  /// True once at least one check has completed (success or failure).
  bool get hasChecked =>
      status != UpdateUiStatus.unknown && status != UpdateUiStatus.checking;

  /// Comma-separated asset names (metadata only — no download in this phase).
  String get assetsSummary => assets.map((a) => a.name).join(', ');

  UpdateState copyWith({
    UpdateUiStatus? status,
    Object? currentVersion = _unset,
    Object? latestVersion = _unset,
    Object? latestTag = _unset,
    bool? updateAvailable,
    Object? releaseUrl = _unset,
    Object? releaseNotes = _unset,
    List<ReleaseAssetInfo>? assets,
    Object? checkedAt = _unset,
    Object? errorMessage = _unset,
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
      releaseUrl:
          identical(releaseUrl, _unset) ? this.releaseUrl : releaseUrl as String?,
      releaseNotes: identical(releaseNotes, _unset)
          ? this.releaseNotes
          : releaseNotes as String?,
      assets: assets ?? this.assets,
      checkedAt:
          identical(checkedAt, _unset) ? this.checkedAt : checkedAt as DateTime?,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }
}

const Object _unset = Object();

class UpdateNotifier extends StateNotifier<UpdateState> {
  UpdateNotifier({
    required UpdateChecker checker,
    required Future<String> Function() readVersion,
  })  : _checker = checker,
        _readVersion = readVersion,
        super(const UpdateState());

  final UpdateChecker _checker;
  final Future<String> Function() _readVersion;

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
  /// on subsequent calls. NOT wired into app startup (see diagnostics_page).
  Future<void> maybeAutoCheck() async {
    if (state.status != UpdateUiStatus.unknown) return;
    await check();
  }

  UpdateState _stateFromResult(
    UpdateCheckResult r, {
    required String fallbackCurrent,
  }) {
    final uiStatus = switch (r.status) {
      UpdateStatus.upToDate => UpdateUiStatus.upToDate,
      UpdateStatus.updateAvailable => UpdateUiStatus.updateAvailable,
      UpdateStatus.error => UpdateUiStatus.failed,
      UpdateStatus.latestUnusable => UpdateUiStatus.latestUnusable,
    };

    String? current = r.currentVersion.isNotEmpty ? r.currentVersion : null;
    current ??= fallbackCurrent.isNotEmpty ? fallbackCurrent : null;

    return UpdateState(
      status: uiStatus,
      currentVersion: current,
      latestVersion: r.latestVersion.isEmpty ? null : r.latestVersion,
      latestTag: r.latestTag.isEmpty ? null : r.latestTag,
      updateAvailable: r.isUpdateAvailable,
      releaseUrl: r.releaseUrl,
      releaseNotes: r.releaseNotes,
      assets: r.assets,
      checkedAt: r.checkedAt,
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

/// App-wide update state. Survives for the container lifetime, so the
/// once-per-session cooldown in [UpdateNotifier.maybeAutoCheck] holds.
final updateNotifierProvider =
    StateNotifierProvider<UpdateNotifier, UpdateState>((ref) {
  return UpdateNotifier(
    checker: ref.watch(updateCheckerProvider),
    readVersion: ref.watch(installedVersionReaderProvider),
  );
});
