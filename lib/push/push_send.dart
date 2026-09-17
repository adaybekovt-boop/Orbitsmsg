// APNs / FCM *send*. Intake is PushGateway. Production send stays off
// until kLiveApnsGateway / kLiveFcmGateway flip after a real fleet.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'opaque_wake.dart';
import 'push_gateway.dart';
import 'push_registration.dart';
import 'apns_provider_jwt.dart';
import 'fcm_oauth_token_request.dart';
import 'fcm_service_account_jwt.dart';

export 'apns_provider_jwt.dart';
export 'apns_send_http.dart';
export 'fcm_oauth_token_request.dart';
export 'fcm_service_account_jwt.dart';
export 'fcm_send_http.dart';

/// iOS APNs topic. Must match the Runner bundle id. Never a Peer ID.
const String kApnsTopic = 'com.orbits.orbitsFlutter';

const String kApnsProductionHost = 'api.push.apple.com';
const String kApnsSandboxHost = 'api.sandbox.push.apple.com';
const String kFcmSendHost = 'fcm.googleapis.com';

/// Background wake TTL. Not a message lifetime SLA.
const int kApnsDefaultTtlSeconds = 86400;
const String kFcmAndroidTtl = '86400s';

class PushSendResult {
  const PushSendResult({required this.sent, required this.reason});

  final bool sent;
  final String reason;
}

/// Env origin for local `tool/push_gateway`. Never Apple / Google.
const String kPushGatewayOriginEnv = 'ORBITS_PUSH_GATEWAY_ORIGIN';

/// True only for loopback HTTP origins used by `tool/push_gateway`.
///
/// Allowed: `http://127.0.0.1`, `http://localhost`, `http://[::1]`
/// (any port). HTTPS, other schemes, and public hosts are false.
bool localPushOriginIsLoopback(String origin) {
  final uri = Uri.tryParse(origin);
  if (uri == null || uri.scheme != 'http' || !uri.hasAuthority) {
    return false;
  }
  final host = uri.host;
  return host == '127.0.0.1' || host == 'localhost' || host == '::1';
}

/// Loopback `tool/push_gateway` only. Missing / public / HTTPS → null.
String? resolvePushGatewayOrigin({Map<String, String>? env}) {
  final raw = env?[kPushGatewayOriginEnv];
  if (raw == null || raw.trim().isEmpty) return null;
  final origin = raw.trim();
  if (!localPushOriginIsLoopback(origin)) return null;
  return origin;
}

/// Deposit wake: local intake, then APNs/FCM builders with **on-device**
/// tokens (still refused while live flags are false), then optional
/// loopback HTTP. Never a dummy `undeployed` token. Never a peer id.
Future<void> dispatchMailboxWake({
  required OpaqueWake wake,
  required DevicePushTokenStore tokens,
  PushSender sender = const PushSender(),
  String? localOrigin,
  Future<void> Function(OpaqueWake wake)? onLocalIntake,
}) async {
  if (onLocalIntake != null) {
    await onLocalIntake(wake);
  }
  final apns = tokens.apnsToken;
  if (apns != null && apns.isNotEmpty) {
    await sender.sendApns(deviceToken: apns, wake: wake);
  }
  final fcm = tokens.fcmToken;
  if (fcm != null && fcm.isNotEmpty) {
    await sender.sendFcm(deviceToken: fcm, wake: wake);
  }
  if (localOrigin != null && localOrigin.isNotEmpty) {
    await sender.sendLocalHttp(origin: localOrigin, wake: wake);
  }
}

class PushSender {
  const PushSender();

  /// Apple HTTP/2. Refused until the live gateway flag is true.
  /// The request is built so tests can prove opacity; it is never sent
  /// while [kLiveApnsGateway] is false.
  ///
  /// The HTTPS POST *shape* is [buildApnsSendHttp] / [dispatchApnsSendHttp]
  /// (injected `post`). This method does not call either while
  /// [kLiveApnsGateway] is false. Neither helper implements HTTP/2 HPACK.
  Future<PushSendResult> sendApns({
    required String deviceToken,
    required OpaqueWake wake,
    bool sandbox = false,
    ApnsProviderKey? providerKey,
    Future<int> Function(
      Uri uri,
      Map<String, String> headers,
      String body,
    )? post, // ignored while kLiveApnsGateway is false
  }) async {
    final request = buildApnsRequest(
      deviceToken: deviceToken,
      wake: wake,
      sandbox: sandbox,
      providerKey: providerKey,
    );
    if (request == null) {
      return const PushSendResult(sent: false, reason: 'unsafe-keys');
    }
    if (!kLiveApnsGateway) {
      // [post] is ignored — do not call dispatchApnsSendHttp / Apple.
      return const PushSendResult(sent: false, reason: 'apns-not-deployed');
    }
    // After kLiveApnsGateway flips, return dispatchApnsSendHttp(
    //   request: request, post: post ?? <https POST>).
    // Do not construct a Dart HTTP client here while the const is
    // false — that branch is dead and the analyzer treats a live
    // POST as unreachable.
    return const PushSendResult(sent: false, reason: 'apns-not-configured');
  }

  /// FCM HTTP v1. Refused until the live gateway flag is true.
  /// A service-account JWT may be built (RS256, not identity-signing-v1)
  /// and the OAuth JWT-bearer form may be built; neither is exchanged or
  /// sent while [kLiveFcmGateway] is false. FCM send Authorization is an
  /// OAuth [accessToken], never the assertion JWT.
  ///
  /// The HTTPS POST shape is [buildFcmSendHttp] / [dispatchFcmSendHttp]
  /// (injected `post`). This method does not call either while
  /// [kLiveFcmGateway] is false.
  Future<PushSendResult> sendFcm({
    required String deviceToken,
    required OpaqueWake wake,
    String projectId = '',
    FcmServiceAccountKey? serviceAccount,
    int? iatSeconds,
    String? accessToken,
    Future<int> Function(
      Uri uri,
      Map<String, String> headers,
      String body,
    )? post, // ignored while kLiveFcmGateway is false
  }) async {
    if (serviceAccount != null) {
      final jwt = buildFcmServiceAccountJwt(
        serviceAccount,
        iatSeconds: iatSeconds,
      );
      if (jwt != null) {
        // Shape only — never HttpClient.post to kFcmOauthTokenUri.
        buildFcmOauthTokenRequest(assertionJwt: jwt);
      }
    }
    final request = buildFcmRequest(
      deviceToken: deviceToken,
      wake: wake,
      projectId: projectId,
      accessToken: accessToken,
    );
    if (request == null) {
      return const PushSendResult(sent: false, reason: 'unsafe-keys');
    }
    if (!kLiveFcmGateway) {
      // [post] is ignored — do not call dispatchFcmSendHttp / Google.
      return const PushSendResult(sent: false, reason: 'fcm-not-deployed');
    }
    // After kLiveFcmGateway flips, return dispatchFcmSendHttp(
    //   request: request, post: post ?? <https POST>).
    // Do not construct a Dart HTTP client here while the const is
    // false — that branch is dead and the analyzer treats a live
    // POST as unreachable.
    return const PushSendResult(sent: false, reason: 'fcm-not-configured');
  }

  /// Local `tool/push_gateway` only. Loopback HTTP. Not Apple / Google.
  Future<PushSendResult> sendLocalHttp({
    required String origin,
    required OpaqueWake wake,
  }) async {
    if (!OpaqueWake.isSafe(wake.toJson())) {
      return const PushSendResult(sent: false, reason: 'unsafe-keys');
    }
    if (origin.isEmpty || !localPushOriginIsLoopback(origin)) {
      final public = origin.contains('apple.com') ||
          origin.contains('googleapis.com');
      return PushSendResult(
        sent: false,
        reason: origin.isEmpty || public
            ? 'refused-public-origin'
            : 'refused-non-loopback',
      );
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
    this.headers = const <String, String>{},
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

/// Same fragment rules as mailbox/wake tokens, duplicated so this
/// library does not import the mailbox client.
bool _deviceTokenIsSafe(String token) {
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
  ApnsProviderKey? providerKey,
  int? iatSeconds,
  int? nowUnix,
  int? expirationUnix,
  String? apnsId,
}) {
  final payload = wake.toJson();
  if (deviceToken.isEmpty || !OpaqueWake.isSafe(payload)) return null;
  if (!_deviceTokenIsSafe(deviceToken)) return null;
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
  final jwt = providerKey == null
      ? null
      : buildApnsProviderJwt(providerKey, iatSeconds: iatSeconds);
  if (jwt != null) {
    headers['authorization'] = 'bearer $jwt';
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

/// Build an FCM HTTP v1 body. Does not send. Null if the wake is unsafe
/// or the device token is empty / looks like a URL or secret fragment.
/// Does not POST to [kFcmOauthTokenUri].
/// [accessToken] is a Google OAuth access_token. Never the service-account
/// assertion JWT (that belongs on [buildFcmOauthTokenRequest] only).
FcmOpaqueRequest? buildFcmRequest({
  required String deviceToken,
  required OpaqueWake wake,
  String projectId = 'orbits',
  String? accessToken,
}) {
  final payload = wake.toJson();
  if (deviceToken.isEmpty || !OpaqueWake.isSafe(payload)) return null;
  if (!_deviceTokenIsSafe(deviceToken)) return null;
  final project = projectId.isEmpty ? 'orbits' : projectId;
  final headers = <String, String>{};
  final token = accessToken?.trim() ?? '';
  if (token.isNotEmpty) {
    if (token.contains('://') ||
        token.contains('peerId') ||
        token.contains('opaqueWakeToken') ||
        token.contains('rootKey') ||
        token.contains('identity-signing-v1') ||
        token.contains('fileKey') ||
        token.split('.').length == 3) {
      return null;
    }
    headers['authorization'] = 'bearer $token';
  }
  return FcmOpaqueRequest(
    host: kFcmSendHost,
    path: '/v1/projects/$project/messages:send',
    headers: headers,
    body: <String, Object?>{
      'message': <String, Object?>{
        'token': deviceToken,
        'android': <String, Object?>{
          'priority': 'normal',
          'ttl': kFcmAndroidTtl,
          if (wake.collapseId.isNotEmpty) 'collapse_key': wake.collapseId,
        },
        'data': <String, String>{
          for (final e in payload.entries) e.key: '${e.value}',
        },
      },
    },
  );
}

