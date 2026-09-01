// Prefer a local Bare binary. Never download a runtime.
// Node is a development fallback only.

import 'dart:ffi';
import 'dart:io';

/// False until a per-OS Bare binary is committed/linked into the app.
const bool kBareBinaryShipped = false;

/// The worklet module graph is Bare-compatible: `package.json` import maps
/// send `node:fs` and friends to `bare-*` modules, and `worklet.js` loads
/// `bare-process` when `process` is missing. Spawn uses a local Bare binary
/// only when that binary and `node_modules/bare-fs` are both present.
/// [kBareBinaryShipped] stays false until every OS slot is in the app bundle.
const bool kBareWorkletRunsOnBareRuntime = true;

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

/// True when the Holepunch `bare-*` stdlib is next to [worklet] so Bare
/// can resolve `bare-fs` / `bare-process` without a remote fetch.
bool bareWorkletGraphPresent(File worklet) {
  var dir = worklet.parent;
  for (var i = 0; i < 6; i++) {
    final fsPkg = File('${dir.path}${Platform.pathSeparator}node_modules'
        '${Platform.pathSeparator}bare-fs${Platform.pathSeparator}package.json');
    if (fsPkg.existsSync()) return true;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return false;
}

/// Resolves how to start the bundled worklet. Order:
/// 1. `ORBITS_BARE_BIN` (absolute local path, experimental)
/// 2. Per-OS slot under `tool/bare/<os-arch>/` only when
///    [kBareWorkletRunsOnBareRuntime] is true and the Bare stdlib is present
/// 3. Legacy `tool/bare/bare.exe` / `tool/bare/bare` (same gate)
/// 4. `node` for CI / desktop harness
BareRuntimeLaunch resolveBareRuntime(File worklet) {
  final workletPath = worklet.absolute.path;
  final env = Platform.environment['ORBITS_BARE_BIN'];
  if (env != null && env.isNotEmpty && File(env).existsSync()) {
    return BareRuntimeLaunch(
      executable: File(env).absolute.path,
      arguments: [workletPath],
      kind: 'bare',
    );
  }
  if (kBareWorkletRunsOnBareRuntime) {
    final local = _localBareBinary();
    if (local != null && bareWorkletGraphPresent(worklet)) {
      return BareRuntimeLaunch(
        executable: local.absolute.path,
        arguments: [workletPath],
        kind: 'bare',
      );
    }
  }
  return BareRuntimeLaunch(
    executable: 'node',
    arguments: [workletPath],
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
