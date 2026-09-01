// Local Holepunch bare-* stdlib next to the worklet.
// Never downloads. Hyperswarm / HyperDHT are not in this zip.

import 'dart:io';

import 'package:archive/archive.dart';

import 'bare_runtime.dart';

const String kBareStdlibZipName = 'bare_stdlib.zip';

const List<String> kBareStdlibRootPackages = [
  'bare-fs',
  'bare-path',
  'bare-crypto',
  'bare-net',
  'bare-events',
  'bare-os',
  'bare-process',
];

bool bareStdlibNameForbidden(String name) {
  final n = name.toLowerCase().replaceAll('\\', '/');
  if (n.contains('://')) return true;
  return n.contains('hyperswarm') ||
      n.contains('hyperdht') ||
      n.contains('dht-rpc');
}

/// Zip next to a bundled Bare binary, plugin native dirs, or the harness.
List<String> bundledStdlibZipCandidates({File? bundledBare}) {
  final sep = Platform.pathSeparator;
  return <String>[
    if (bundledBare != null)
      '${bundledBare.parent.path}$sep$kBareStdlibZipName',
    'packages${sep}orbits_transport_linux${sep}linux$sep$kBareStdlibZipName',
    'packages${sep}orbits_transport_windows${sep}windows$sep$kBareStdlibZipName',
    'packages${sep}orbits_transport_macos${sep}macos$sep$kBareStdlibZipName',
    'packages${sep}orbits_transport_ios${sep}ios$sep$kBareStdlibZipName',
    'packages${sep}orbits_transport_android${sep}android${sep}src${sep}main${sep}assets$sep$kBareStdlibZipName',
    'tool${sep}connectivity_harness$sep$kBareStdlibZipName',
  ];
}

File? findLocalBareStdlibZip({File? bundledBare}) {
  for (final path in bundledStdlibZipCandidates(bundledBare: bundledBare)) {
    if (isLocalBarePath(path)) return File(path);
  }
  return null;
}

/// Copy or unzip local bare-* modules beside [worklet] so Bare can resolve
/// `bare-fs` without Node. No-op when the graph is already present.
Future<void> ensureLocalBareStdlib(
  File worklet, {
  File? bundledBare,
}) async {
  if (bareWorkletGraphPresent(worklet)) return;
  final zip = findLocalBareStdlibZip(bundledBare: bundledBare);
  if (zip == null) return;
  extractBareStdlibZip(zip, worklet.parent);
}

void extractBareStdlibZip(File zip, Directory dest) {
  if (!isLocalBarePath(zip.path)) return;
  final bytes = zip.readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final file in archive) {
    final name = file.name.replaceAll('\\', '/');
    if (name.contains('..') || bareStdlibNameForbidden(name)) continue;
    if (!file.isFile) continue;
    final out = File(
      '${dest.path}${Platform.pathSeparator}${name.replaceAll('/', Platform.pathSeparator)}',
    );
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(file.content);
  }
}
