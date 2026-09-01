// Prefer a local Bare binary. Never download a runtime.
// Node is a development fallback only.

import 'dart:io';

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
/// 2. `tool/bare/bare.exe` / `tool/bare/bare` next to the repo
/// 3. `node` for CI / desktop harness
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
  final names = Platform.isWindows
      ? const ['tool/bare/bare.exe', 'tool/bare/bare']
      : const ['tool/bare/bare', 'tool/bare/bare.exe'];
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
