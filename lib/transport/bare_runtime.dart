// Prefer a local Bare binary. Never download a runtime.
// Node is a development fallback only.

import 'dart:ffi';
import 'dart:io';

/// False until a per-OS Bare binary is committed/linked into the app.
const bool kBareBinaryShipped = false;

class BareRuntimeLaunch {
  const BareRuntimeLaunch({
    required this.executable,
    required this.arguments,
    required this.kind,
  });

  final String executable;
  final List<String> arguments;
  final String kind;

  bool get isBare => kind == 'bare';
}

const Map<String, String> kBareOsSlots = {
  'linux-x64': 'tool/bare/linux-x64/bare',
  'linux-arm64': 'tool/bare/linux-arm64/bare',
  'darwin-x64': 'tool/bare/darwin-x64/bare',
  'darwin-arm64': 'tool/bare/darwin-arm64/bare',
  'windows-x64': 'tool/bare/windows-x64/bare.exe',
  'android-arm64': 'tool/bare/android-arm64/bare',
  'ios-arm64': 'tool/bare/ios-arm64/bare',
};

String currentBareOsArch() {
  switch (Abi.current()) {
    case Abi.linuxX64:
      return 'linux-x64';
    case Abi.linuxArm64:
      return 'linux-arm64';
    case Abi.macosX64:
      return 'darwin-x64';
    case Abi.macosArm64:
      return 'darwin-arm64';
    case Abi.windowsX64:
      return 'windows-x64';
    case Abi.androidArm64:
      return 'android-arm64';
    case Abi.iosArm:
    case Abi.iosArm64:
      return 'ios-arm64';
    default:
      return Platform.isWindows ? 'windows-x64' : 'linux-x64';
  }
}

/// Per-OS slots under tool/bare/. None of these files ship in this tree yet.
String bareOsSlot({String? osArch}) {
  final key = osArch ?? currentBareOsArch();
  return kBareOsSlots[key] ??
      (Platform.isWindows ? 'tool/bare/bare.exe' : 'tool/bare/bare');
}

/// Resolves how to start the bundled worklet. Order:
/// 1. `ORBITS_BARE_BIN` (absolute local path)
/// 2. Per-OS slot under `tool/bare/<os-arch>/`
/// 3. Legacy `tool/bare/bare.exe` / `tool/bare/bare`
/// 4. `node` for CI / desktop harness
BareRuntimeLaunch resolveBareRuntime(File worklet) {
  final env = Platform.environment['ORBITS_BARE_BIN'];
  if (env != null && env.isNotEmpty && File(env).existsSync()) {
    return BareRuntimeLaunch(
      executable: env,
      arguments: [worklet.path],
      kind: 'bare',
    );
  }
  final local = _localBareBinary();
  if (local != null) {
    return BareRuntimeLaunch(
      executable: local.path,
      arguments: [worklet.path],
      kind: 'bare',
    );
  }
  return BareRuntimeLaunch(
    executable: 'node',
    arguments: [worklet.path],
    kind: 'node',
  );
}

File? _localBareBinary() {
  final names = <String>[
    bareOsSlot(),
    if (Platform.isWindows) 'tool/bare/bare.exe',
    'tool/bare/bare',
    if (!Platform.isWindows) 'tool/bare/bare.exe',
  ];
  for (final name in names) {
    final file = File(name);
    if (file.existsSync()) return file;
  }
  return null;
}

bool bareManifestForbidsRemoteFetch(Map<String, Object?> manifest) {
  return manifest['remoteFetch'] == false &&
      manifest['downloadUrl'] == null &&
      manifest['bundleUrl'] == null;
}

bool bareManifestHasOsSlots(Map<String, Object?> manifest) {
  final binaries = manifest['binaries'];
  if (binaries is! Map) return false;
  for (final key in kBareOsSlots.keys) {
    if (!binaries.containsKey(key)) return false;
  }
  return true;
}
