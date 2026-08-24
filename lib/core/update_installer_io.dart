// dart:io implementation of the installer launcher (desktop/mobile builds).

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'authenticode.dart';
import 'authenticode_io.dart';
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
    AuthenticodeVerifier? verifier,
    AuthenticodePolicy? policy,
  })  : _launcher = launcher ?? _startDetached,
        // kIsWeb is always false here (this lib only loads off-web); gate on the
        // real OS. Overridable so tests can simulate either platform.
        _isWindows = isWindows ?? (!kIsWeb && Platform.isWindows),
        // Real Windows uses PowerShell. Everywhere else (including tests that
        // set isWindows:true on Linux) fail closed unless a verifier is injected.
        _verifier = verifier ??
            (!kIsWeb && Platform.isWindows
                ? PowershellAuthenticodeVerifier()
                : const FailClosedAuthenticodeVerifier()),
        _policy = policy ?? kDefaultAuthenticodePolicy;

  final InstallerConfig config;
  final DetachedLauncher _launcher;
  final bool _isWindows;
  final AuthenticodeVerifier _verifier;
  final AuthenticodePolicy _policy;

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

    // Empty pin: do not pretend the file is untrusted. Install is off
    // until a real cert SHA-256 is provisioned.
    if (!isAuthenticodePinProvisioned(_policy.allowedThumbprints)) {
      return const InstallLaunchResult(
        InstallLaunchStatus.autoUpdateUnprovisioned,
        message: kUpdateAutoUpdateUnavailableMessage,
      );
    }

    // U-1: never launch until Authenticode is valid AND the publisher pin
    // matches. An adjacent `.sha256` file is ignored — hashes without a
    // publisher signature are not a trust boundary.
    final signature = await _verifier.verify(installerPath);
    if (!_policy.allows(signature)) {
      return InstallLaunchResult(
        InstallLaunchStatus.signatureUntrusted,
        message: signature.message ??
            'Authenticode ${signature.status.name} subject=${signature.subject}',
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
