// Prefer a local Bare binary. Never download a runtime.
// Node is a development fallback only.

import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;

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

/// Resolves how to start the bundled worklet. Order:
/// 1. `ORBITS_BARE_BIN` (absolute local path)
/// 2. Executable/application bundle relative layout
/// 3. Repository `build/orbits-bare/` / `tool/bare/` layout
/// 4. `node` for CI / desktop harness
BareRuntimeLaunch resolveBareRuntime(
  File worklet, {
  bool allowNode = true,
  bool releaseMode = false,
}) {
  final env = Platform.environment['ORBITS_BARE_BIN'];
  if (env != null && env.isNotEmpty) {
    if (releaseMode) {
      throw StateError('ORBITS_BARE_BIN is disabled in release builds');
    }
    final file = File(env);
    if (!file.existsSync() || !file.isAbsolute) {
      throw StateError('ORBITS_BARE_BIN must be an absolute local path');
    }
    return BareRuntimeLaunch(
      executable: file.path,
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
  if (!allowNode || releaseMode) {
    throw StateError('BARE_RUNTIME_MISSING');
  }
  return BareRuntimeLaunch(
    executable: 'node',
    arguments: [worklet.path],
    kind: 'node',
  );
}

File? _localBareBinary() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final names = <String>[
    // 1. Executable/application bundle relative paths:
    if (Platform.isWindows) ...[
      '$exeDir${Platform.pathSeparator}bare.exe',
      '$exeDir${Platform.pathSeparator}lib${Platform.pathSeparator}bare.exe',
      '$exeDir${Platform.pathSeparator}bin${Platform.pathSeparator}bare.exe',
    ],
    if (Platform.isLinux || Platform.isMacOS) ...[
      '$exeDir${Platform.pathSeparator}bare',
      '$exeDir${Platform.pathSeparator}lib${Platform.pathSeparator}bare',
      '$exeDir${Platform.pathSeparator}bin${Platform.pathSeparator}bare',
    ],
    // 2. Repository build tree:
    if (Platform.isLinux) ...[
      'build/orbits-bare/linux-x64/bare',
      'build/orbits-bare/linux-arm64/bare',
    ],
    if (Platform.isMacOS) ...[
      'build/orbits-bare/darwin-arm64/bare',
      'build/orbits-bare/darwin-x64/bare',
    ],
    if (Platform.isWindows) ...[
      'build/orbits-bare/win32-x64/bare.exe',
      'build/orbits-bare/win32-arm64/bare.exe',
    ],
    if (Platform.isWindows) 'tool/bare/bare.exe' else 'tool/bare/bare',
    if (Platform.isWindows) 'tool/bare/bare' else 'tool/bare/bare.exe',
  ];
  for (final name in names) {
    final file = File(name);
    if (!file.existsSync()) continue;
    final sidecar = File('${file.path}.sha256');
    if (!sidecar.existsSync()) continue;
    try {
      final expectedSha = sidecar
          .readAsStringSync()
          .trim()
          .split(RegExp(r'\s+'))
          .first
          .toLowerCase();
      if (expectedSha.length != 64) continue;
      final actualSha =
          sha256.convert(file.readAsBytesSync()).toString().toLowerCase();
      if (expectedSha == actualSha) {
        return file;
      }
    } catch (_) {}
  }
  return null;
}

bool bareManifestForbidsRemoteFetch(Map<String, Object?> manifest) {
  return manifest['remoteFetch'] == false &&
      manifest['downloadUrl'] == null &&
      manifest['bundleUrl'] == null;
}
