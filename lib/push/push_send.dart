// APNs / FCM *send*. Intake is PushGateway. Production send stays off
// until kLiveApnsGateway / kLiveFcmGateway flip after a real fleet.

import 'dart:convert';
import 'dart:io';

import 'opaque_wake.dart';
import 'push_gateway.dart';

/// iOS APNs topic. Must match the Runner bundle id. Never a Peer ID.
const String kApnsTopic = 'com.orbits.orbitsFlutter';

const String kApnsProductionHost = 'api.push.apple.com';
const String kApnsSandboxHost = 'api.sandbox.push.apple.com';
const String kFcmSendHost = 'fcm.googleapis.com';

class PushSendResult {
  const PushSendResult({required this.sent, required this.reason});

  final bool sent;
  final String reason;
}

class PushSender {
  const PushSender();

  /// Apple HTTP/2. Refused until the live gateway flag is true.
  /// The request is built so tests can prove opacity; it is never sent
  /// while [kLiveApnsGateway] is false.
  Future<PushSendResult> sendApns({
    required String deviceToken,
    required OpaqueWake wake,
    bool sandbox = false,
  }) async {
    final request = buildApnsRequest(
      deviceToken: deviceToken,
      wake: wake,
      sandbox: sandbox,
    );
    if (request == null) {
      return const PushSendResult(sent: false, reason: 'unsafe-keys');
    }
    if (!kLiveApnsGateway) {
      return const PushSendResult(sent: false, reason: 'apns-not-deployed');
    }
    return const PushSendResult(sent: false, reason: 'apns-not-configured');
  }

  /// FCM HTTP v1. Refused until the live gateway flag is true.
  Future<PushSendResult> sendFcm({
    required String deviceToken,
    required OpaqueWake wake,
    String projectId = '',
  }) async {
    final request = buildFcmRequest(
      deviceToken: deviceToken,
      wake: wake,
      projectId: projectId,
    );
    if (request == null) {
      return const PushSendResult(sent: false, reason: 'unsafe-keys');
    }
    if (!kLiveFcmGateway) {
      return const PushSendResult(sent: false, reason: 'fcm-not-deployed');
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

class ApnsOpaqueRequest {
  const ApnsOpaqueRequest({
    required this.host,
    required this.path,
    required this.headers,
    required this.body,
  });

  final String host;
  final String path;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}

class FcmOpaqueRequest {
  const FcmOpaqueRequest({
    required this.host,
    required this.path,
    required this.body,
  });

  final String host;
  final String path;
  final Map<String, Object?> body;
}

/// Build an APNs HTTP/2 body. Does not send. Null if the wake is unsafe
/// or the token is empty.
ApnsOpaqueRequest? buildApnsRequest({
  required String deviceToken,
  required OpaqueWake wake,
  bool sandbox = false,
}) {
  final payload = wake.toJson();
  if (deviceToken.isEmpty || !OpaqueWake.isSafe(payload)) return null;
  return ApnsOpaqueRequest(
    host: sandbox ? kApnsSandboxHost : kApnsProductionHost,
    path: '/3/device/$deviceToken',
    headers: const {
      'apns-push-type': 'background',
      'apns-priority': '5',
      'apns-topic': kApnsTopic,
    },
    body: <String, Object?>{
      'aps': <String, Object?>{'content-available': 1},
      ...payload,
    },
  );
}

/// Build an FCM HTTP v1 body. Does not send.
FcmOpaqueRequest? buildFcmRequest({
  required String deviceToken,
  required OpaqueWake wake,
  String projectId = 'orbits',
}) {
  final payload = wake.toJson();
  if (deviceToken.isEmpty || !OpaqueWake.isSafe(payload)) return null;
  final project = projectId.isEmpty ? 'orbits' : projectId;
  return FcmOpaqueRequest(
    host: kFcmSendHost,
    path: '/v1/projects/$project/messages:send',
    body: <String, Object?>{
      'message': <String, Object?>{
        'token': deviceToken,
        'data': <String, String>{
          for (final e in payload.entries) e.key: '${e.value}',
        },
      },
    },
  );
}

