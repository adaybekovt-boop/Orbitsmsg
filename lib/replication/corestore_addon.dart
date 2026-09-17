// Holepunch Corestore native addon probe.
// The in-tree journal is a local stand-in. Do not fetch a remote .node.

import 'dart:io';

/// False until a per-OS addon is linked at build time.
const bool kHolepunchCorestoreAddonLinked = false;

/// The worklet may `require('corestore')` when that module is installed
/// next to the harness. That is still not a native `.node` addon.
const bool kCorestoreJsModuleOptional = true;

const bool kCorestoreAddonRemoteFetch = false;

const String kCorestoreAddonSlot = 'tool/bare/addons/corestore.node';

/// Bare-native addon slot. Same rule: local file only, never downloaded.
const String kCorestoreBareAddonSlot = 'tool/bare/addons/corestore.bare';

const String kCorestoreAddonManifestPath =
    'tool/bare/addons/CORESTORE.manifest';

/// Local filesystem addon path. Any `://` URL is refused — never fetched.
bool corestoreAddonPathIsLocal(String path) {
  final p = path.trim();
  if (p.isEmpty) return false;
  if (p.contains('://')) return false;
  return true;
}

bool corestoreAddonPresent({String path = kCorestoreAddonSlot}) {
  if (kCorestoreAddonRemoteFetch) return false;
  if (!corestoreAddonPathIsLocal(path)) return false;
  return File(path).existsSync();
}

bool corestoreBareAddonPresent({String path = kCorestoreBareAddonSlot}) {
  if (kCorestoreAddonRemoteFetch) return false;
  if (!corestoreAddonPathIsLocal(path)) return false;
  return File(path).existsSync();
}

/// Vendor/embed scripts must refuse every URL scheme and never curl/wget.
bool corestoreAddonScriptForbidsRemoteFetch(String script) {
  return script.contains('NEVER downloads') &&
      script.contains('refusing remote Corestore addon URL') &&
      script.contains('http://*') &&
      script.contains('https://*') &&
      script.contains('*://*') &&
      script.contains('kHolepunchCorestoreAddonLinked stays false') &&
      !script.contains('curl') &&
      !script.contains('wget');
}

bool corestoreAddonManifestForbidsRemoteFetch(Map<String, Object?> manifest) {
  return manifest['remoteFetch'] == false &&
      manifest['downloadUrl'] == null &&
      manifest['bundleUrl'] == null &&
      manifest['linked'] == false;
}

bool corestoreAddonIsProductionReady() {
  return kHolepunchCorestoreAddonLinked &&
      !kCorestoreAddonRemoteFetch &&
      corestoreAddonPresent();
}
