// OS → Dart hop for opaque APNs / FCM wakes.
// The live gateway stays off (`kLiveApnsGateway`). This channel only
// accepts the three safe keys and forwards them to [OpaqueWakeService].

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'opaque_wake.dart';
import 'wake_service.dart';

const String kOpaqueWakeChannelName = 'app.orbits/wake';

class OpaqueWakeChannel {
  OpaqueWakeChannel({
    required this.onWake,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel(kOpaqueWakeChannelName);

  final MethodChannel _channel;
  final Future<void> Function(Map<String, Object?> payload) onWake;

  void attach() {
    if (BindingBase.debugBindingType() == null) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'opaqueWake') return;
      final raw = call.arguments;
      if (raw is! Map) return;
      final payload = <String, Object?>{};
      raw.forEach((key, value) {
        payload['$key'] = value;
      });
      if (!OpaqueWake.isSafe(payload)) return;
      await onWake(payload);
    });
  }

  void detach() {
    if (BindingBase.debugBindingType() == null) return;
    _channel.setMethodCallHandler(null);
  }
}

void bindOpaqueWakeChannel(OpaqueWakeService wake, {MethodChannel? channel}) {
  OpaqueWakeChannel(
    channel: channel,
    onWake: (payload) => wake.handle(payload),
  ).attach();
}
