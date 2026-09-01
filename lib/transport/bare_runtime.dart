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
/// 2. Plugin-bundled Bare from [bundledBare] (`barePath()`)
/// 3. Per-OS slot under plugin native dirs / `tool/bare/<os-arch>/`
///    only when [kBareWorkletRunsOnBareRuntime] is true and the Bare
///    stdlib is present
/// 4. `node` for CI / desktop harness
BareRuntimeLaunch resolveBareRuntime(
  File worklet, {
  File? bundledBare,
}) {
  final workletPath = worklet.absolute.path;
  final env = Platform.environment['ORBITS_BARE_BIN'];
  if (env != null && env.isNotEmpty && isLocalBarePath(env)) {
    return BareRuntimeLaunch(
      executable: File(env).absolute.path,
      arguments: [workletPath],
      kind: 'bare',
    );
  }
  if (kBareWorkletRunsOnBareRuntime && bareWorkletGraphPresent(worklet)) {
    if (bundledBare != null && isLocalBarePath(bundledBare.path)) {
      return BareRuntimeLaunch(
        executable: File(bundledBare.path).absolute.path,
        arguments: [workletPath],
        kind: 'bare',
      );
    }
    final local = _localBareBinary();
    if (local != null) {
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
  for (final name in bundledBareCandidates()) {
    if (isLocalBarePath(name)) return File(name);
  }
  return null;
}

/// Local files Dart may spawn. Plugin-native copies (CI embed) come
/// before `tool/bare/` slots. None of these are downloaded at runtime.
List<String> bundledBareCandidates({String? osArch}) {
  final arch = osArch ?? currentBareOsArch();
  final sep = Platform.pathSeparator;
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  return <String>[
    '$exeDir${sep}bare',
    '$exeDir${sep}bare.exe',
    '$exeDir${sep}lib${sep}bare',
    if (arch == 'linux-arm64')
      'packages/orbits_transport_linux/linux/bare-arm64',
    'packages/orbits_transport_linux/linux/bare',
    if (arch == 'darwin-x64')
      'packages/orbits_transport_macos/macos/bare-x64',
    'packages/orbits_transport_macos/macos/bare',
    'packages/orbits_transport_windows/windows/bare.exe',
    'packages/orbits_transport_android/android/src/main/assets/bare',
    'packages/orbits_transport_ios/ios/bare',
    bareOsSlot(osArch: arch),
    if (Platform.isWindows) 'tool/bare/bare.exe',
    'tool/bare/bare',
    if (!Platform.isWindows) 'tool/bare/bare.exe',
  ];
}

bool isLocalBarePath(String path) {
  final p = path.trim();
  if (p.isEmpty) return false;
  if (p.startsWith('http://') || p.startsWith('https://')) return false;
  return File(p).existsSync();
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

/// Every vendor tarball must have a sha256 pin. Dart still never fetches.
bool bareManifestPinsAllVendorHashes(Map<String, Object?> manifest) {
  final vendor = manifest['vendor'];
  if (vendor is! Map) return false;
  final assets = vendor['assets'];
  if (assets is! Map) return false;
  for (final key in kBareOsSlots.keys) {
    final asset = assets[key];
    if (asset is! Map) return false;
    final hash = asset['sha256'];
    if (hash is! String || hash.length != 64) return false;
  }
  return true;
}
