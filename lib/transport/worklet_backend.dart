// Worklet backend pick for NativeTransportHost.
// Default product rollout stays off, so this is never used on the live
// PeerJS path. When rollout ≠ off, prefer Hyperswarm if the module is
// present *and* bootstrap is explicit; otherwise loopback. Never the
// public DHT.

import 'dart:io';

import '../core/feature_flags.dart';

bool hyperswarmModulePresent({String harnessRoot = 'tool/connectivity_harness'}) {
  final pkg = File('$harnessRoot/node_modules/hyperswarm/package.json');
  return pkg.existsSync();
}

/// Hyperswarm only when rollout ≠ off, the module exists, *and* an
/// explicit bootstrap list was provided. Missing bootstrap is loopback,
/// never the public DHT.
String preferredWorkletBackend({
  bool? modulePresent,
  bool? hasBootstrap,
}) {
  if (!isHyperswarmTransportEnabled()) return 'loopback';
  final present = modulePresent ?? hyperswarmModulePresent();
  final bootstrap = hasBootstrap ?? false;
  return present && bootstrap ? 'hyperswarm' : 'loopback';
}

/// If a hyperswarm spawn/start fails, the host retries with loopback.
String fallbackWorkletBackend(String preferred) {
  if (preferred == 'hyperswarm') return 'loopback';
  return preferred;
}
