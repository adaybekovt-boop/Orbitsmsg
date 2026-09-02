// Native APNs / FCM token registration. Dart never registers while the
// live gateway flags are false, so we do not prompt for push permission
// on the default PeerJS product path.

import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'opaque_wake.dart';
import 'push_gateway.dart';

const MethodChannel kOrbitsPushChannel = MethodChannel('app.orbits/push');

/// Device tokens stay on-device. Never journal / Hypercore / mailbox.
class DevicePushTokenStore {
  String? apnsToken;
  String? fcmToken;

  void setApns(String token) {
    if (token.isEmpty) return;
    if (!opaqueWakeTokenIsSafe(token)) return;
    apnsToken = token;
  }

  void setFcm(String token) {
    if (token.isEmpty) return;
    if (!opaqueWakeTokenIsSafe(token)) return;
    fcmToken = token;
  }

  Map<String, Object?> debugSummary() => <String, Object?>{
        'hasApns': apnsToken != null,
        'hasFcm': fcmToken != null,
      };
}

class PushRegistration {
  PushRegistration({
    DevicePushTokenStore? tokens,
    MethodChannel? channel,
  })  : tokens = tokens ?? DevicePushTokenStore(),
        _channel = channel ?? kOrbitsPushChannel;

  final DevicePushTokenStore tokens;
  final MethodChannel _channel;

  bool get shouldRegisterNative => kLiveApnsGateway || kLiveFcmGateway;

  /// No-op on the default path. A later flag flip may ask the OS.
  Future<void> registerNativeIfDeployed() async {
    if (kIsWeb || !shouldRegisterNative) return;
    await _channel.invokeMethod<void>('register');
  }

  void acceptToken(Map<String, Object?> payload) {
    if (_payloadHasForbiddenKey(payload, HashSet<Object>.identity())) return;
    final apns = payload['apns'];
    final fcm = payload['fcm'];
    if (apns is String) tokens.setApns(apns);
    if (fcm is String) tokens.setFcm(fcm);
  }
}

/// Cycle-safe nested walk for [OpaqueWake.forbiddenKeys] (replication
/// secrets plus UX wake keys). Ciphertext [List<int>] is a leaf.
bool _payloadHasForbiddenKey(Object? value, Set<Object> seen) {
  if (value == null || value is bool || value is num || value is String) {
    return false;
  }
  if (value is List<int>) return false;
  if (value is Map) {
    if (!seen.add(value)) return false;
    for (final entry in value.entries) {
      if (OpaqueWake.forbiddenKeys.contains('${entry.key}')) return true;
      if (_payloadHasForbiddenKey(entry.value, seen)) return true;
    }
    return false;
  }
  if (value is Iterable) {
    if (!seen.add(value)) return false;
    for (final item in value) {
      if (_payloadHasForbiddenKey(item, seen)) return true;
    }
    return false;
  }
  return false;
}
