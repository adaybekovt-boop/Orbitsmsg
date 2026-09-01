// Native APNs / FCM token registration. Dart never registers while the
// live gateway flags are false, so we do not prompt for push permission
// on the default PeerJS product path.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'push_gateway.dart';

const MethodChannel kOrbitsPushChannel = MethodChannel('app.orbits/push');

/// Device tokens stay on-device. Never journal / Hypercore / mailbox.
class DevicePushTokenStore {
  String? apnsToken;
  String? fcmToken;

  void setApns(String token) {
    if (token.isEmpty) return;
    apnsToken = token;
  }

  void setFcm(String token) {
    if (token.isEmpty) return;
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
    final apns = payload['apns'] as String?;
    final fcm = payload['fcm'] as String?;
    if (apns != null) tokens.setApns(apns);
    if (fcm != null) tokens.setFcm(fcm);
  }
}
