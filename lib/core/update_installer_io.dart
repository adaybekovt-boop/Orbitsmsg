// dart:io implementation of the installer launcher (desktop/mobile builds).

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'update_installer.dart';

/// Launches a detached process. Returns true if it started (pid > 0). Injectable
/// so tests never spawn a real process.
typedef DetachedLauncher = Future<bool> Function(String exe, List<String> args);

UpdateInstaller createUpdateInstaller({
  InstallerConfig config = const InstallerConfig(),
}) =>
    IoUpdateInstaller(config: config);

class IoUpdateInstaller implements UpdateInstaller {
  IoUpdateInstaller({
    this.config = const InstallerConfig(),
    DetachedLauncher? launcher,
    bool? isWindows,
  })  : _launcher = launcher ?? _startDetached,
        // kIsWeb is always false here (this lib only loads off-web); gate on the
        // real OS. Overridable so tests can simulate either platform.
        _isWindows = isWindows ?? (!kIsWeb && Platform.isWindows);

  final InstallerConfig config;
  final DetachedLauncher _launcher;
  final bool _isWindows;

  static Future<bool> _startDetached(String exe, List<String> args) async {
    // Detached so the installer keeps running after we exit. We deliberately do
    // NOT wait on it — the app is about to close.
    final process =
        await Process.start(exe, args, mode: ProcessStartMode.detached);
    return process.pid > 0;
  }

  @override
  Future<InstallLaunchResult> launch(String installerPath) async {
    if (!_isWindows) {
      return const InstallLaunchResult(InstallLaunchStatus.unsupportedPlatform);
    }

    final file = File(installerPath);
    if (!file.existsSync()) {
      return const InstallLaunchResult(InstallLaunchStatus.fileMissing);
    }
    if (!installerPath.toLowerCase().endsWith('.exe')) {
      return const InstallLaunchResult(
        InstallLaunchStatus.invalidFile,
        message: 'Installer must be an .exe',
      );
    }
    int length;
    try {
      length = file.lengthSync();
    } catch (e) {
      return InstallLaunchResult(InstallLaunchStatus.error, message: '$e');
    }
    if (length <= 0) {
      return const InstallLaunchResult(
        InstallLaunchStatus.invalidFile,
        message: 'Installer file is empty',
      );
    }

    final args = config.innoArgs();
    try {
      final ok = await _launcher(installerPath, args);
      return ok
          ? InstallLaunchResult(InstallLaunchStatus.launched, argsUsed: args)
          : InstallLaunchResult(InstallLaunchStatus.launchFailed, argsUsed: args);
    } catch (e) {
      return InstallLaunchResult(
        InstallLaunchStatus.launchFailed,
        message: '$e',
        argsUsed: args,
      );
    }
  }
}

Future<void> requestAppExit() async {
  // Give the detached installer a moment to come up before we vanish.
  await Future<void>.delayed(const Duration(milliseconds: 400));
  // Desktop: a clean process exit lets the installer replace our files. On
  // mobile this also just ends the app (the install path is Windows-only).
  exit(0);
}
