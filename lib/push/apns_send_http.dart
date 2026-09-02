// APNs send POST *shape*. Ordinary HTTPS description (not HTTP/2 HPACK).
// Builds the request and dispatches through an injected [post] callback.
// Never opens a socket. Never constructs a Dart HTTP client.
// Never implements HTTP/2 framing or HPACK.
// PushSender.sendApns still refuses while kLiveApnsGateway is false and
// does not call [dispatchApnsSendHttp].
//
// Authorization may be an Apple provider ES256 JWT (bearer). That is
// not identity-signing-v1, not the Hyperswarm Noise key, not a ratchet
// scalar, and not a fileKey.

import 'dart:convert';

import '../transport/layers.dart';
import 'push_send.dart';

/// Substring fragments that must never appear in APNs host/path/headers.
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

/// HTTPS POST description for [kApnsProductionHost] / [kApnsSandboxHost].
/// [body] is JSON. Does not send. Does not speak HTTP/2.
class ApnsSendHttpRequest {
  const ApnsSendHttpRequest({
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

bool _isApnsHost(String host) =>
    host == kApnsProductionHost || host == kApnsSandboxHost;

/// Build an APNs POST shape. Null if the host/path/headers/body are
/// unsafe. Does not POST. Does not encode HPACK.
ApnsSendHttpRequest? buildApnsSendHttp(ApnsOpaqueRequest request) {
  if (!_isApnsHost(request.host)) return null;
  if (request.path.isEmpty ||
      !request.path.startsWith('/3/device/') ||
      request.path.contains('://')) {
    return null;
  }
  if (_hasForbiddenSecret(request.host, includeOpaqueWake: true) ||
      _hasForbiddenSecret(request.path, includeOpaqueWake: true)) {
    return null;
  }
  for (final e in request.headers.entries) {
    if (_hasForbiddenSecret(e.key, includeOpaqueWake: true)) {
      return null;
    }
    // Authorization may be a provider JWT. Other header values must
    // not carry identity / ratchet / discovery secrets.
    if (e.key.toLowerCase() == 'authorization') {
      if (_hasForbiddenSecret(e.value, includeOpaqueWake: true)) {
        return null;
      }
      continue;
    }
    if (_hasForbiddenSecret(e.value, includeOpaqueWake: true)) {
      return null;
    }
  }
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
  return ApnsSendHttpRequest(
    method: 'POST',
    host: request.host,
    path: request.path,
    headers: headers,
    body: encoded,
  );
}

/// Call injected [post] with the built HTTPS request. Never constructs
/// a Dart HTTP client. The [post] callback is responsible for HTTP/2
/// if it actually talks to Apple; this function does not.
/// Maps 200 → sent / `apns-http`; other codes → `http-N`.
Future<PushSendResult> dispatchApnsSendHttp({
  required ApnsOpaqueRequest request,
  required Future<int> Function(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) post,
}) async {
  final http = buildApnsSendHttp(request);
  if (http == null) {
    return const PushSendResult(sent: false, reason: 'unsafe-keys');
  }
  final uri = Uri.parse('https://${http.host}${http.path}');
  if (uri.scheme != 'https' || !_isApnsHost(uri.host)) {
    return const PushSendResult(sent: false, reason: 'unsafe-keys');
  }
  final status = await post(uri, http.headers, http.body);
  if (status == 200) {
    return const PushSendResult(sent: true, reason: 'apns-http');
  }
  return PushSendResult(sent: false, reason: 'http-$status');
}

bool _hasForbiddenSecret(String s, {required bool includeOpaqueWake}) {
  for (final fragment in _kForbiddenSecretFragments) {
    if (s.contains(fragment)) return true;
  }
  return includeOpaqueWake && s.contains('opaqueWakeToken');
}

/// Reject [kForbiddenReplicationFields] as exact JSON keys plus secret
/// fragments in keys or string values. `opaqueWakeToken` is allowed in
/// the APNs body (same as FCM `message.data`).
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
