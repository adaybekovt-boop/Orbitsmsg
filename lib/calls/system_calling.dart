// System incoming-call UI. No VoIP PushKit / always-on P2P promise.
// Handle is an opaque hash — never a peer ID.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'opaque_call_handle.dart';

class SystemCalling {
  SystemCalling({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('app.orbits/calling');

  final MethodChannel _channel;

  Future<void> reportIncoming({
    required String callId,
    bool video = false,
  }) async {
    final handle = opaqueCallHandle(callId);
    try {
      await _channel.invokeMethod<void>('reportIncoming', {
        'opaqueCallId': handle,
        'displayName': kSystemCallDisplayName,
        'video': video,
      });
    } on MissingPluginException {
      if (kDebugMode) {
        debugPrint('[calling] no system calling plugin');
      }
    }
  }

  Future<void> endCall(String callId) async {
    try {
      await _channel.invokeMethod<void>('endCall', {
        'opaqueCallId': opaqueCallHandle(callId),
      });
    } on MissingPluginException {
      // In-app overlay still works.
    }
  }
}

final systemCalling = SystemCalling();
