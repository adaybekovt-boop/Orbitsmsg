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

const String kCorestoreAddonManifestPath =
    'tool/bare/addons/CORESTORE.manifest';

bool corestoreAddonPresent({String path = kCorestoreAddonSlot}) {
  if (kCorestoreAddonRemoteFetch) return false;
  return File(path).existsSync();
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
