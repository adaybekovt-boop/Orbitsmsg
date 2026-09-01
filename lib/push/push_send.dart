// APNs / FCM *send*. Intake is PushGateway. Production send stays off
// until kLiveApnsGateway / kLiveFcmGateway flip after a real fleet.

import 'dart:convert';
import 'dart:io';

import 'opaque_wake.dart';
import 'push_gateway.dart';

class PushSendResult {
  const PushSendResult({required this.sent, required this.reason});

  final bool sent;
  final String reason;
}

class PushSender {
  const PushSender();

  /// Apple HTTP/2. Refused until the live gateway flag is true.
  Future<PushSendResult> sendApns({
    required String deviceToken,
    required OpaqueWake wake,
  }) async {
    if (!kLiveApnsGateway) {
      return const PushSendResult(sent: false, reason: 'apns-not-deployed');
    }
    if (!OpaqueWake.isSafe(wake.toJson())) {
      return const PushSendResult(sent: false, reason: 'unsafe-keys');
    }
    return const PushSendResult(sent: false, reason: 'apns-not-configured');
  }

  /// FCM HTTP v1. Refused until the live gateway flag is true.
  Future<PushSendResult> sendFcm({
    required String deviceToken,
    required OpaqueWake wake,
  }) async {
    if (!kLiveFcmGateway) {
      return const PushSendResult(sent: false, reason: 'fcm-not-deployed');
    }
    if (!OpaqueWake.isSafe(wake.toJson())) {
      return const PushSendResult(sent: false, reason: 'unsafe-keys');
    }
    return const PushSendResult(sent: false, reason: 'fcm-not-configured');
  }

  /// Local `tool/push_gateway` only. Not Apple / Google.
  Future<PushSendResult> sendLocalHttp({
    required String origin,
    required OpaqueWake wake,
  }) async {
    if (!OpaqueWake.isSafe(wake.toJson())) {
      return const PushSendResult(sent: false, reason: 'unsafe-keys');
    }
    if (origin.isEmpty ||
        origin.contains('apple.com') ||
        origin.contains('googleapis.com')) {
      return const PushSendResult(sent: false, reason: 'refused-public-origin');
    }
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$origin/v1/wake'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(wake.toJson()));
      final res = await req.close();
      if (res.statusCode != 200) {
        return PushSendResult(sent: false, reason: 'http-${res.statusCode}');
      }
      return const PushSendResult(sent: true, reason: 'local-http');
    } finally {
      client.close(force: true);
    }
  }
}
