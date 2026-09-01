// Worklet backend pick for NativeTransportHost.
// Default product rollout stays off, so this is never used on the live
// PeerJS path. When rollout ≠ off, prefer Hyperswarm and fall back to
// loopback if the module is missing.

import 'dart:io';

import '../core/feature_flags.dart';

bool hyperswarmModulePresent({String harnessRoot = 'tool/connectivity_harness'}) {
  final pkg = File('$harnessRoot/node_modules/hyperswarm/package.json');
  return pkg.existsSync();
}

/// Hyperswarm only when the native path is enabled *and* the module exists.
String preferredWorkletBackend({bool? modulePresent}) {
  if (!isHyperswarmTransportEnabled()) return 'loopback';
  final present = modulePresent ?? hyperswarmModulePresent();
  return present ? 'hyperswarm' : 'loopback';
}

/// If a hyperswarm spawn/start fails, the host retries with loopback.
String fallbackWorkletBackend(String preferred) {
  if (preferred == 'hyperswarm') return 'loopback';
  return preferred;
}
