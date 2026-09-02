// Google OAuth 2.0 JWT-bearer token *request* for FCM HTTP v1.
// Builds the POST shape. Does not exchange the JWT. Does not send
// FCM. PushSender still refuses while kLiveFcmGateway is false.
//
// Not identity-signing-v1, not the Hyperswarm Noise key, and not a
// ratchet scalar. The assertion is the service-account RS256 JWT.

import 'fcm_service_account_jwt.dart';

/// RFC 7523 grant used at [kFcmOauthTokenUri].
const String kFcmOauthGrantType =
    'urn:ietf:params:oauth:grant-type:jwt-bearer';

class FcmOauthTokenRequest {
  const FcmOauthTokenRequest({
    required this.host,
    required this.path,
    required this.method,
    required this.headers,
    required this.body,
  });

  final String host;
  final String path;
  final String method;
  final Map<String, String> headers;
  final String body;
}

/// Form-urlencoded token request. Null if [assertionJwt] is not a JWT.
/// Never opens a socket.
FcmOauthTokenRequest? buildFcmOauthTokenRequest({
  required String assertionJwt,
}) {
  if (assertionJwt.isEmpty) return null;
  if (assertionJwt.split('.').length != 3) return null;
  if (assertionJwt.contains('://')) return null;
  if (assertionJwt.contains('peerId') ||
      assertionJwt.contains('opaqueWakeToken') ||
      assertionJwt.contains('rootKey') ||
      assertionJwt.contains('identity-signing-v1')) {
    return null;
  }
  final uri = Uri.parse(kFcmOauthTokenUri);
  if (uri.host != 'oauth2.googleapis.com' || uri.path != '/token') {
    return null;
  }
  final grant = Uri.encodeQueryComponent(kFcmOauthGrantType);
  final assertion = Uri.encodeQueryComponent(assertionJwt);
  return FcmOauthTokenRequest(
    host: uri.host,
    path: uri.path.isEmpty ? '/token' : uri.path,
    method: 'POST',
    headers: const <String, String>{
      'content-type': 'application/x-www-form-urlencoded',
    },
    body: 'grant_type=$grant&assertion=$assertion',
  );
}
