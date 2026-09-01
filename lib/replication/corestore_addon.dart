// Holepunch Corestore native addon probe.
// The in-tree journal is a local stand-in. Do not fetch a remote .node.

import 'dart:io';

/// False until a per-OS addon is linked at build time.
const bool kHolepunchCorestoreAddonLinked = false;

const bool kCorestoreAddonRemoteFetch = false;

const String kCorestoreAddonSlot = 'tool/bare/addons/corestore.node';

bool corestoreAddonPresent({String path = kCorestoreAddonSlot}) {
  if (kCorestoreAddonRemoteFetch) return false;
  return File(path).existsSync();
}

bool corestoreAddonIsProductionReady() {
  return kHolepunchCorestoreAddonLinked &&
      !kCorestoreAddonRemoteFetch &&
      corestoreAddonPresent();
}
