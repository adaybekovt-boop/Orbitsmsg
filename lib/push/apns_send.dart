// APNs send *shape* and refuse-to-send. Live gateway stays off.
// Not identity-signing-v1. Not the Hyperswarm Noise key.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'opaque_wake.dart';

/// iOS APNs topic. Must match the Runner bundle id. Never a Peer ID.
const String kApnsTopic = 'com.orbits.orbitsFlutter';

const String kApnsProductionHost = 'api.push.apple.com';
const String kApnsSandboxHost = 'api.sandbox.push.apple.com';

/// Background wake TTL. Not a message lifetime SLA.
const int kApnsDefaultTtlSeconds = 86400;

/// Live Apple send. Keep false until a real fleet is deployed.
const bool kLiveApnsGateway = false;

class PushSendResult {
  const PushSendResult({required this.sent, required this.reason});

  final bool sent;
  final String reason;
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

/// Deterministic APNs `apns-id` from the collapse id. Never a Peer ID.
String orbitsApnsId(String collapseId) {
  final digest = sha256.convert(utf8.encode('orbits-apns-id-v1|$collapseId'));
  final h = digest.toString();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20, 32)}';
}

bool deviceTokenIsSafe(String token) {
  if (token.isEmpty) return false;
  if (token.contains('://')) return false;
  if (token.contains('peerId')) return false;
  if (token.contains('fileKey')) return false;
  if (token.contains('rootKey')) return false;
  if (token.contains('discoverySecret')) return false;
  return true;
}

/// Build an APNs HTTP/2 body. Does not send. Null if the wake is unsafe
/// or the device token is empty / looks like a URL or secret fragment.
ApnsOpaqueRequest? buildApnsRequest({
  required String deviceToken,
  required OpaqueWake wake,
  bool sandbox = false,
  String? authorization,
  int? nowUnix,
  int? expirationUnix,
  String? apnsId,
}) {
  final payload = wake.toJson();
  if (deviceToken.isEmpty || !OpaqueWake.isSafe(payload)) return null;
  if (!deviceTokenIsSafe(deviceToken)) return null;
  final now = nowUnix ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final headers = <String, String>{
    'apns-push-type': 'background',
    'apns-priority': '5',
    'apns-topic': kApnsTopic,
    'apns-expiration': '${expirationUnix ?? now + kApnsDefaultTtlSeconds}',
    'apns-id': apnsId ?? orbitsApnsId(wake.collapseId),
  };
  if (wake.collapseId.isNotEmpty) {
    headers['apns-collapse-id'] = wake.collapseId;
  }
  final auth = authorization?.trim() ?? '';
  if (auth.isNotEmpty) {
    headers['authorization'] = auth;
  }
  return ApnsOpaqueRequest(
    host: sandbox ? kApnsSandboxHost : kApnsProductionHost,
    path: '/3/device/$deviceToken',
    headers: headers,
    body: <String, Object?>{
      'aps': <String, Object?>{'content-available': 1},
      ...payload,
    },
  );
}

class PushSender {
  const PushSender();

  /// Apple HTTP/2. Refused until the live gateway flag is true.
  /// The HTTPS POST *shape* is [buildApnsSendHttp] / [dispatchApnsSendHttp].
  /// This method does not call either while [kLiveApnsGateway] is false.
  Future<PushSendResult> sendApns({
    required String deviceToken,
    required OpaqueWake wake,
    bool sandbox = false,
    String? authorization,
    Future<int> Function(Uri uri, Map<String, String> headers, String body)?
    post, // ignored while kLiveApnsGateway is false
  }) async {
    final request = buildApnsRequest(
      deviceToken: deviceToken,
      wake: wake,
      sandbox: sandbox,
      authorization: authorization,
    );
    if (request == null) {
      return const PushSendResult(sent: false, reason: 'unsafe-keys');
    }
    if (!kLiveApnsGateway) {
      return const PushSendResult(sent: false, reason: 'apns-not-deployed');
    }
    return const PushSendResult(sent: false, reason: 'apns-not-configured');
  }
}
