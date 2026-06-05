// Web stub for the installer launcher. The web build can't launch a local
// installer, so every call reports "unsupported" and app-exit is a no-op.

import 'update_installer.dart';

UpdateInstaller createUpdateInstaller({
  InstallerConfig config = const InstallerConfig(),
}) =>
    const _StubUpdateInstaller();

class _StubUpdateInstaller implements UpdateInstaller {
  const _StubUpdateInstaller();

  @override
  Future<InstallLaunchResult> launch(String installerPath) async =>
      const InstallLaunchResult(InstallLaunchStatus.unsupportedPlatform);
}

Future<void> requestAppExit() async {
  // No process to exit on web — closing is the browser tab's job.
}
