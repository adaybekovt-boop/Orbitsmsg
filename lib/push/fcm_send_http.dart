// FCM HTTP v1 send POST *shape*. Ordinary HTTPS POST (not APNs HTTP/2).
// Builds the request and dispatches through an injected [post] callback.
// Never opens a socket. Never constructs a Dart HTTP client.
// PushSender.sendFcm still refuses while kLiveFcmGateway is false and
// does not call [dispatchFcmSendHttp].
//
// Authorization is a Google OAuth access_token (bearer), never a 3-part
// JWT (the assertion belongs on the OAuth token request only).
// Not identity-signing-v1, not the Hyperswarm Noise key, not a ratchet
// scalar, and not a fileKey.

import 'dart:convert';

import '../transport/layers.dart';
import 'push_send.dart';

/// Substring fragments that must never appear in FCM host/path/headers/body.
/// Covers [kForbiddenReplicationFields] except overly-generic tokens (`kek`,
/// `skipped`) that would false-positive as `contains()` matches.
const List<String> _kForbiddenSecretFragments = <String>[
  'peerId',
  'rootKey',
  'identity-signing-v1',
  'fileKey',
  'discoverySecret',
  'sharedDiscoverySecret',
  'vaultKek',
  'fileKeyB64',
  'sendCk',
  'recvCk',
  'dhPriv',
  'privBytes',
  'attachmentBytes',
  'plaintext',
  'password',
];

/// HTTPS POST to [kFcmSendHost]. [body] is JSON. Does not send.
class FcmSendHttpRequest {
  const FcmSendHttpRequest({
    required this.method,
    required this.host,
    required this.path,
    required this.headers,
    required this.body,
  });

  final String method;
  final String host;
  final String path;
  final Map<String, String> headers;
  final String body;
}

/// Build an FCM HTTP v1 POST. Null if the host/path/authorization/body
/// are unsafe. Does not POST.
FcmSendHttpRequest? buildFcmSendHttp(FcmOpaqueRequest request) {
  if (request.host != kFcmSendHost) return null;
  if (request.path.isEmpty ||
      !request.path.startsWith('/') ||
      request.path.contains('://')) {
    return null;
  }
  if (_hasForbiddenSecret(request.host, includeOpaqueWake: true) ||
      _hasForbiddenSecret(request.path, includeOpaqueWake: true)) {
    return null;
  }
  for (final e in request.headers.entries) {
    if (_hasForbiddenSecret(e.key, includeOpaqueWake: true) ||
        _hasForbiddenSecret(e.value, includeOpaqueWake: true)) {
      return null;
    }
  }
  final auth = request.headers['authorization'] ?? '';
  if (auth.isNotEmpty && _authorizationLooksLikeJwt(auth)) return null;
  if (_bodyHasForbiddenKeys(request.body)) return null;
  final String encoded;
  try {
    encoded = jsonEncode(request.body);
  } catch (_) {
    return null;
  }
  if (_hasForbiddenSecret(encoded, includeOpaqueWake: false)) return null;
  final headers = <String, String>{
    ...request.headers,
    'content-type': 'application/json',
  };
  return FcmSendHttpRequest(
    method: 'POST',
    host: request.host,
    path: request.path,
    headers: headers,
    body: encoded,
  );
}

/// Call injected [post] with the built HTTPS request. Never constructs
/// a Dart HTTP client. Maps 200 → sent / `fcm-http`; other codes → `http-N`.
Future<PushSendResult> dispatchFcmSendHttp({
  required FcmOpaqueRequest request,
  required Future<int> Function(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) post,
}) async {
  final http = buildFcmSendHttp(request);
  if (http == null) {
    return const PushSendResult(sent: false, reason: 'unsafe-keys');
  }
  final uri = Uri.parse('https://${http.host}${http.path}');
  if (uri.scheme != 'https' || uri.host != kFcmSendHost) {
    return const PushSendResult(sent: false, reason: 'unsafe-keys');
  }
  final status = await post(uri, http.headers, http.body);
  if (status == 200) {
    return const PushSendResult(sent: true, reason: 'fcm-http');
  }
  return PushSendResult(sent: false, reason: 'http-$status');
}

bool _authorizationLooksLikeJwt(String authorization) {
  var token = authorization.trim();
  const prefix = 'bearer ';
  if (token.toLowerCase().startsWith(prefix)) {
    token = token.substring(prefix.length).trim();
  }
  // 3-part JWT (header.payload.signature) — two dots, three segments.
  return token.split('.').length == 3;
}

bool _hasForbiddenSecret(String s, {required bool includeOpaqueWake}) {
  for (final fragment in _kForbiddenSecretFragments) {
    if (s.contains(fragment)) return true;
  }
  return includeOpaqueWake && s.contains('opaqueWakeToken');
}

/// Reject [kForbiddenReplicationFields] as exact JSON keys (so `kek` /
/// `skipped` are caught without substring false positives) plus secret
/// fragments in keys or string values. `opaqueWakeToken` is allowed in
/// FCM `message.data`.
bool _bodyHasForbiddenKeys(Object? node) {
  if (node is Map) {
    for (final e in node.entries) {
      final key = e.key.toString();
      if (kForbiddenReplicationFields.contains(key)) return true;
      if (_hasForbiddenSecret(key, includeOpaqueWake: false)) return true;
      if (_bodyHasForbiddenKeys(e.value)) return true;
    }
    return false;
  }
  if (node is List) {
    for (final v in node) {
      if (_bodyHasForbiddenKeys(v)) return true;
    }
    return false;
  }
  if (node is String) {
    return _hasForbiddenSecret(node, includeOpaqueWake: false);
  }
  return false;
}
