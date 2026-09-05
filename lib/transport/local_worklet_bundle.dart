// Verify the hashed in-app worklet tree. Production Bare must never
// fetch remote executable JavaScript.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const String kWorkletManifestPath = 'tool/connectivity_harness/BUNDLE.manifest';
const String kWorkletScriptPath = 'tool/connectivity_harness/src/worklet.js';

class LocalWorkletBundle {
  const LocalWorkletBundle({
    required this.ipc,
    required this.remoteJs,
    required this.expectedSha256,
    required this.actualSha256,
    required this.scriptExists,
  });

  final String ipc;
  final bool remoteJs;
  final String expectedSha256;
  final String actualSha256;
  final bool scriptExists;

  bool get hashMatches =>
      scriptExists &&
      expectedSha256.length == 64 &&
      expectedSha256 == actualSha256;

  bool get allowsRemoteJs => remoteJs;

  void assertSafeForProduction() {
    if (remoteJs) {
      throw StateError('production Bare must not fetch remote JS');
    }
    if (!scriptExists) {
      throw StateError('local Bare bundle missing');
    }
    if (!hashMatches) {
      throw StateError('local bundle hash mismatch');
    }
    if (ipc != 'orbits-bare-ipc-v1') {
      throw StateError('unsupported IPC version');
    }
  }
}

LocalWorkletBundle inspectLocalWorkletBundle({
  String manifestPath = kWorkletManifestPath,
  String scriptPath = kWorkletScriptPath,
}) {
  final manifestFile = File(manifestPath);
  final script = File(scriptPath);
  if (!manifestFile.existsSync()) {
    return const LocalWorkletBundle(
      ipc: '',
      remoteJs: false,
      expectedSha256: '',
      actualSha256: '',
      scriptExists: false,
    );
  }
  final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map;
  final files = manifest['files'];
  if (files is Map) {
    final srcDir = script.parent;
    for (final entry in files.entries) {
      final name = entry.key.toString();
      final expected = entry.value.toString();
      final file = File('${srcDir.path}${Platform.pathSeparator}$name');
      if (!file.existsSync()) {
        throw StateError('local Bare bundle missing: $name');
      }
      final digest = sha256.convert(file.readAsBytesSync()).toString();
      if (digest != expected) {
        throw StateError('local bundle hash mismatch: $name');
      }
    }
  }
  final actual = script.existsSync()
      ? sha256.convert(script.readAsBytesSync()).toString()
      : '';
  return LocalWorkletBundle(
    ipc: manifest['ipc'] as String? ?? '',
    remoteJs: manifest['remoteJs'] == true,
    expectedSha256: manifest['workletSha256'] as String? ?? '',
    actualSha256: actual,
    scriptExists: script.existsSync(),
  );
}
