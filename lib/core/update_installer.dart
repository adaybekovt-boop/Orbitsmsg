// Windows installer launch (auto-update Phase 4).
//
// Launches a previously-downloaded Inno Setup installer (`orbits-windows-x64.exe`)
// and lets IT update the app. We NEVER overwrite the running .exe or write into
// the install dir ourselves — the installer does that. Non-Windows platforms
// degrade gracefully (unsupported).
//
// dart:io (Process/File/exit) lives in the conditional `_io`/`_stub` impls so
// this stays importable from the web build.

import 'update_installer_io.dart'
    if (dart.library.html) 'update_installer_stub.dart' as impl;

enum InstallLaunchStatus {
  launched,
  unsupportedPlatform,
  fileMissing,
  invalidFile,
  launchFailed,
  error,
}

class InstallLaunchResult {
  const InstallLaunchResult(
    this.status, {
    this.message,
    this.argsUsed = const <String>[],
  });

  final InstallLaunchStatus status;
  final String? message;

  /// The installer flags actually passed (for diagnostics/tests).
  final List<String> argsUsed;

  bool get launched => status == InstallLaunchStatus.launched;
}

/// Inno Setup launch flags. Defaults to a SAFE, visible install:
///   /SP-          skip the "This will install…" nag
///   /NORESTART    never let the installer reboot Windows
///   /CURRENTUSER  per-user install (no UAC elevation needed)
/// `silent` adds `/VERYSILENT` — OFF by default. Fully-silent install can hide
/// prompts or fail while the app is still running, so it's opt-in and not the
/// only path. Flip [silent] (or wire a setting) once verified on real builds.
class InstallerConfig {
  const InstallerConfig({this.silent = false});

  final bool silent;

  List<String> innoArgs() => <String>[
        '/SP-',
        '/NORESTART',
        '/CURRENTUSER',
        if (silent) '/VERYSILENT',
      ];
}

/// Launches the downloaded installer. The default implementation is created via
/// [createUpdateInstaller]; tests use the dart:io impl directly with an injected
/// launcher.
abstract class UpdateInstaller {
  Future<InstallLaunchResult> launch(String installerPath);
}

UpdateInstaller createUpdateInstaller({
  InstallerConfig config = const InstallerConfig(),
}) =>
    impl.createUpdateInstaller(config: config);

/// Request a safe app exit so the installer can replace files while the app is
/// not running. Desktop: process exit (after a short grace). Web/other: no-op.
Future<void> requestAppExit() => impl.requestAppExit();
