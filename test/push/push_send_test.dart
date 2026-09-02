import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/push/opaque_wake.dart';
import 'package:orbits_flutter/push/push_gateway.dart';
import 'package:orbits_flutter/push/push_registration.dart';
import 'package:orbits_flutter/push/push_send.dart';
import 'package:pointycastle/export.dart' as pc;

import '../helpers/pointycastle_ecdh.dart';

void main() {
  test('production APNs/FCM send is refused while flags are off', () async {
    expect(kLiveApnsGateway, isFalse);
    expect(kLiveFcmGateway, isFalse);
    const sender = PushSender();
    const wake = OpaqueWake(
      opaqueWakeToken: 'tok',
      collapseId: 'c1',
      protocolVersion: 1,
    );
    expect((await sender.sendApns(deviceToken: 'a', wake: wake)).sent, isFalse);
    expect((await sender.sendApns(deviceToken: 'a', wake: wake)).reason,
        'apns-not-deployed');
    expect((await sender.sendFcm(deviceToken: 'f', wake: wake)).sent, isFalse);
    expect((await sender.sendFcm(deviceToken: 'f', wake: wake)).reason,
        'fcm-not-deployed');
    expect(
      (await sender.sendLocalHttp(origin: 'https://api.push.apple.com', wake: wake))
          .sent,
      isFalse,
    );
  });

  test('device tokens stay off the journal', () {
    final store = DevicePushTokenStore();
    store.setApns('abc');
    store.setFcm('def');
    expect(store.debugSummary(), {'hasApns': true, 'hasFcm': true});
    expect(store.debugSummary().containsKey('apnsToken'), isFalse);
    expect(store.debugSummary().containsKey('fcmToken'), isFalse);
  });

  test('native push registration is skipped while gateways are off', () async {
    final reg = PushRegistration();
    expect(reg.shouldRegisterNative, isFalse);
    await reg.registerNativeIfDeployed();
    reg.acceptToken({'apns': 'aa', 'fcm': 'bb'});
    expect(reg.tokens.apnsToken, 'aa');
    expect(reg.tokens.fcmToken, 'bb');
  });

  test('local opaque wake HTTP talks to loopback intake', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });
    server.listen((req) async {
      expect(req.uri.path, '/v1/wake');
      final body = jsonDecode(await utf8.decodeStream(req)) as Map;
      expect(body.containsKey('text'), isFalse);
      expect(body.containsKey('peerId'), isFalse);
      req.response
        ..statusCode = 200
        ..write(jsonEncode({'ok': true, 'deployed': false}));
      await req.response.close();
    });
    const sender = PushSender();
    final result = await sender.sendLocalHttp(
      origin: 'http://127.0.0.1:${server.port}',
      wake: const OpaqueWake(
        opaqueWakeToken: 'tok',
        collapseId: 'c1',
        protocolVersion: 1,
      ),
    );
    expect(result.sent, isTrue);
    expect(result.reason, 'local-http');
  });

  test('localPushOriginIsLoopback allows only loopback HTTP', () {
    expect(localPushOriginIsLoopback('http://127.0.0.1'), isTrue);
    expect(localPushOriginIsLoopback('http://127.0.0.1:8080'), isTrue);
    expect(localPushOriginIsLoopback('http://localhost'), isTrue);
    expect(localPushOriginIsLoopback('http://localhost:9'), isTrue);
    expect(localPushOriginIsLoopback('http://[::1]'), isTrue);
    expect(localPushOriginIsLoopback('http://[::1]:1'), isTrue);

    expect(localPushOriginIsLoopback(''), isFalse);
    expect(localPushOriginIsLoopback('https://127.0.0.1'), isFalse);
    expect(localPushOriginIsLoopback('https://localhost'), isFalse);
    expect(localPushOriginIsLoopback('https://[::1]'), isFalse);
    expect(localPushOriginIsLoopback('https://example.invalid'), isFalse);
    expect(localPushOriginIsLoopback('http://example.invalid'), isFalse);
    expect(localPushOriginIsLoopback('ftp://127.0.0.1/wake'), isFalse);
    expect(localPushOriginIsLoopback('file:///tmp/wake'), isFalse);
    expect(localPushOriginIsLoopback('https://api.push.apple.com'), isFalse);
    expect(localPushOriginIsLoopback('https://fcm.googleapis.com'), isFalse);
    expect(localPushOriginIsLoopback('http://127.0.0.1.example.invalid'), isFalse);
  });

  test('sendLocalHttp refuses non-loopback origins before HTTP', () async {
    expect(kLiveApnsGateway, isFalse);
    expect(kLiveFcmGateway, isFalse);
    const sender = PushSender();
    const wake = OpaqueWake(
      opaqueWakeToken: 'tok',
      collapseId: 'c1',
      protocolVersion: 1,
    );
    for (final origin in <String>[
      'https://example.invalid',
      'http://example.invalid',
      'ftp://127.0.0.1/wake',
      'file:///tmp/wake',
      '',
    ]) {
      final result = await sender.sendLocalHttp(origin: origin, wake: wake);
      expect(result.sent, isFalse, reason: origin);
      expect(result.reason, isNot('local-http'), reason: origin);
    }
    expect(kLiveApnsGateway, isFalse);
    expect(kLiveFcmGateway, isFalse);
  });

  test('APNs/FCM request builders stay opaque and are not sent', () {
    const wake = OpaqueWake(
      opaqueWakeToken: 'tok',
      collapseId: 'c1',
      protocolVersion: 1,
    );
    final apns = buildApnsRequest(deviceToken: 'devtoken', wake: wake)!;
    expect(apns.host, kApnsProductionHost);
    expect(apns.path, '/3/device/devtoken');
    expect(apns.headers['apns-topic'], kApnsTopic);
    expect(apns.headers['apns-push-type'], 'background');
    expect(apns.headers['apns-collapse-id'], 'c1');
    expect(apns.headers['apns-expiration'], isNotNull);
    expect(int.parse(apns.headers['apns-expiration']!), greaterThan(0));
    expect(apns.headers['apns-id'], orbitsApnsId('c1'));
    expect(apns.headers['apns-id'], isNot(contains('peerId')));
    expect(OpaqueWake.isSafe(apns.body), isTrue);
    expect(apns.body.containsKey('peerId'), isFalse);
    expect(apns.body.containsKey('text'), isFalse);
    expect((apns.body['aps'] as Map)['content-available'], 1);
    expect(apns.headers.containsKey('authorization'), isFalse);

    final fcm = buildFcmRequest(deviceToken: 'ftok', wake: wake)!;
    expect(fcm.host, kFcmSendHost);
    expect(fcm.path, contains('/v1/projects/'));
    expect(fcm.path, contains('messages:send'));
    final data = ((fcm.body['message'] as Map)['data'] as Map);
    expect(data['opaqueWakeToken'], 'tok');
    expect(data.containsKey('peerId'), isFalse);
    final android = (fcm.body['message'] as Map)['android'] as Map;
    expect(android['priority'], 'normal');
    expect(android['ttl'], kFcmAndroidTtl);
    expect(android['collapse_key'], 'c1');

    expect(
      buildApnsRequest(
        deviceToken: 'x',
        wake: const OpaqueWake(
          opaqueWakeToken: 't',
          collapseId: 'c',
          protocolVersion: 1,
        ),
      ),
      isNotNull,
    );
    expect(
      buildApnsRequest(
        deviceToken: '',
        wake: wake,
      ),
      isNull,
    );
  });

  test('APNs/FCM builders refuse URL and secret-fragment device tokens', () {
    const wake = OpaqueWake(
      opaqueWakeToken: 'tok',
      collapseId: 'c1',
      protocolVersion: 1,
    );
    expect(
      buildApnsRequest(
        deviceToken: 'https://evil.example/tok',
        wake: wake,
      ),
      isNull,
    );
    expect(
      buildFcmRequest(
        deviceToken: 'https://evil.example/tok',
        wake: wake,
      ),
      isNull,
    );
    expect(buildApnsRequest(deviceToken: 'has-fileKey', wake: wake), isNull);
    expect(buildFcmRequest(deviceToken: 'has-fileKey', wake: wake), isNull);
    expect(
      buildApnsRequest(deviceToken: 'peerId-fragment', wake: wake),
      isNull,
    );
    expect(
      buildFcmRequest(deviceToken: 'peerId-fragment', wake: wake),
      isNull,
    );
    expect(buildApnsRequest(deviceToken: 'devtoken', wake: wake), isNotNull);
    expect(buildFcmRequest(deviceToken: 'ftok', wake: wake), isNotNull);
    expect(kLiveApnsGateway, isFalse);
    expect(kLiveFcmGateway, isFalse);
  });

  test('APNs provider JWT is ES256, opaque, and still not sent', () async {
    installPointyCastleEcdh();
    final pair = await generateP256EcdsaKey();
    final key = ApnsProviderKey(
      teamId: 'TEAMID1234',
      keyId: 'KEYID12345',
      privateKeyD: pair.d,
    );
    const wake = OpaqueWake(
      opaqueWakeToken: 'tok',
      collapseId: 'c1',
      protocolVersion: 1,
    );
    final req = buildApnsRequest(
      deviceToken: 'devtoken',
      wake: wake,
      providerKey: key,
      iatSeconds: 1700000000,
    )!;
    final auth = req.headers['authorization']!;
    expect(auth.startsWith('bearer '), isTrue);
    final jwt = auth.substring(7);
    expect(
      verifyApnsProviderJwt(
        jwt: jwt,
        publicX: pair.x,
        publicY: pair.y,
        teamId: 'TEAMID1234',
        keyId: 'KEYID12345',
      ),
      isTrue,
    );
    expect(jwt.split('.'), hasLength(3));
    expect(jwt, isNot(contains('peerId')));
    expect(jwt, isNot(contains('opaqueWakeToken')));
    expect(req.body.containsKey('authorization'), isFalse);
    expect(OpaqueWake.isSafe(req.body), isTrue);

    const sender = PushSender();
    final result = await sender.sendApns(
      deviceToken: 'devtoken',
      wake: wake,
      providerKey: key,
    );
    expect(result.sent, isFalse);
    expect(result.reason, 'apns-not-deployed');
    expect(kLiveApnsGateway, isFalse);

    expect(
      buildApnsProviderJwt(
        const ApnsProviderKey(
          teamId: '',
          keyId: 'KEYID12345',
          privateKeyD: <int>[1],
        ),
      ),
      isNull,
    );
    expect(
      File('lib/push/apns_provider_jwt.dart').readAsStringSync(),
      isNot(contains('identity_key')),
    );
    expect(
      File('lib/push/apns_provider_jwt.dart').readAsStringSync(),
      contains('Not identity-signing-v1'),
    );
  });

  test('FCM service-account JWT is RS256, opaque, and still not sent', () async {
    final pair = generateFcmRsaKeyForTests();
    final priv = pair.privateKey as pc.RSAPrivateKey;
    final pub = pair.publicKey as pc.RSAPublicKey;
    final pem = encodeFcmPkcs8Pem(priv);
    expect(parseFcmPkcs8Pem(pem)!.modulus, priv.modulus);
    final key = FcmServiceAccountKey(
      clientEmail: 'orbits-fcm@orbits.iam.gserviceaccount.com',
      privateKeyPem: pem,
      privateKeyId: 'kid-fcm-1',
    );
    const wake = OpaqueWake(
      opaqueWakeToken: 'tok',
      collapseId: 'c1',
      protocolVersion: 1,
    );
    final jwt = buildFcmServiceAccountJwt(key, iatSeconds: 1700000000)!;
    expect(
      verifyFcmServiceAccountJwt(
        jwt: jwt,
        modulus: fcmModulusBytes(pub),
        publicExponent: fcmPublicExponentBytes(pub),
        clientEmail: 'orbits-fcm@orbits.iam.gserviceaccount.com',
        privateKeyId: 'kid-fcm-1',
      ),
      isTrue,
    );
    expect(jwt.split('.'), hasLength(3));
    expect(jwt, isNot(contains('peerId')));
    expect(jwt, isNot(contains('opaqueWakeToken')));
    expect(jwt, isNot(contains('rootKey')));

    final req = buildFcmRequest(deviceToken: 'ftok', wake: wake)!;
    expect(req.headers.containsKey('authorization'), isFalse);
    expect(jsonEncode(req.headers), isNot(contains(jwt)));
    expect(jsonEncode(req.body), isNot(contains(jwt)));
    final data = Map<String, Object?>.from(
      (req.body['message'] as Map)['data'] as Map,
    );
    expect(OpaqueWake.isSafe(data), isTrue);
    expect(data.containsKey('peerId'), isFalse);
    expect(
      File('lib/push/fcm_service_account_jwt.dart').readAsStringSync(),
      isNot(contains('identity_key')),
    );
    expect(
      File('lib/push/fcm_service_account_jwt.dart').readAsStringSync(),
      contains('Not identity-signing-v1'),
    );
    expect(
      File('lib/push/fcm_service_account_jwt.dart').readAsStringSync(),
      contains('Never POSTs to the OAuth token URI'),
    );

    const sender = PushSender();
    final result = await sender.sendFcm(
      deviceToken: 'ftok',
      wake: wake,
      serviceAccount: key,
    );
    expect(result.sent, isFalse);
    expect(result.reason, 'fcm-not-deployed');
    expect(kLiveFcmGateway, isFalse);

    final oauth = buildFcmOauthTokenRequest(assertionJwt: jwt)!;
    expect(oauth.host, 'oauth2.googleapis.com');
    expect(oauth.path, '/token');
    expect(oauth.method, 'POST');
    expect(
      oauth.headers['content-type'],
      'application/x-www-form-urlencoded',
    );
    expect(oauth.body, contains('grant_type='));
    expect(
      oauth.body,
      contains(Uri.encodeQueryComponent(kFcmOauthGrantType)),
    );
    expect(oauth.body, contains('assertion='));
    expect(oauth.body, contains(Uri.encodeQueryComponent(jwt)));
    expect(oauth.body, isNot(contains('peerId')));
    expect(oauth.body, isNot(contains('rootKey')));
    expect(
      File('lib/push/fcm_oauth_token_request.dart').readAsStringSync(),
      isNot(contains('HttpClient')),
    );
    expect(
      File('lib/push/fcm_oauth_token_request.dart').readAsStringSync(),
      contains('Never opens a socket'),
    );

    final token = parseFcmOauthTokenResponse(
      '{"access_token":"ya29-opaque","token_type":"Bearer","expires_in":3600}',
    )!;
    expect(token.accessToken, 'ya29-opaque');
    expect(token.tokenType, 'Bearer');
    expect(token.expiresIn, 3600);
    expect(
      parseFcmOauthTokenResponse('{"access_token":"https://evil.example/t"}'),
      isNull,
    );
    expect(parseFcmOauthTokenResponse('{"token":"nope"}'), isNull);
    expect(
      parseFcmOauthTokenResponse('{"access_token":"x","peerId":"ORBIT"}'),
      isNull,
    );
    expect(
      File('lib/push/fcm_oauth_token_request.dart').readAsStringSync(),
      contains('parseFcmOauthTokenResponse'),
    );
    expect(
      File('lib/push/fcm_oauth_token_request.dart').readAsStringSync(),
      isNot(contains('HttpClient')),
    );

    final withTok = buildFcmRequest(
      deviceToken: 'ftok',
      wake: wake,
      accessToken: token.accessToken,
    )!;
    expect(withTok.headers['authorization'], 'bearer ya29-opaque');
    expect(withTok.headers['authorization'], isNot(contains(jwt)));
    expect(jsonEncode(withTok.body), isNot(contains(jwt)));
    expect(buildFcmRequest(deviceToken: 'ftok', wake: wake, accessToken: jwt),
        isNull);
    expect(
      buildFcmRequest(
        deviceToken: 'ftok',
        wake: wake,
        accessToken: 'https://evil.example/t',
      ),
      isNull,
    );
    expect(
      File('lib/push/push_send.dart').readAsStringSync(),
      contains('Never the service-account'),
    );

    expect(
      buildFcmOauthTokenRequest(assertionJwt: 'not-a-jwt'),
      isNull,
    );
    expect(
      buildFcmOauthTokenRequest(assertionJwt: 'a.b.c://evil'),
      isNull,
    );
    expect(
      buildFcmServiceAccountJwt(
        const FcmServiceAccountKey(
          clientEmail: 'not-an-email',
          privateKeyPem: '-----BEGIN PRIVATE KEY-----\nQQ==\n-----END PRIVATE KEY-----',
        ),
      ),
      isNull,
    );
  });

  test('FCM HTTP v1 POST is built and dispatched only through an injected post',
      () async {
    const wake = OpaqueWake(
      opaqueWakeToken: 'tok',
      collapseId: 'c1',
      protocolVersion: 1,
    );
    final opaque = buildFcmRequest(
      deviceToken: 'ftok',
      wake: wake,
      accessToken: 'ya29-opaque',
    )!;
    final http = buildFcmSendHttp(opaque)!;
    expect(http.method, 'POST');
    expect(http.host, kFcmSendHost);
    expect(http.host, 'fcm.googleapis.com');
    expect(http.path, opaque.path);
    expect(http.headers['content-type'], 'application/json');
    expect(http.headers['authorization'], 'bearer ya29-opaque');
    expect(http.headers['authorization']!.split('.'), isNot(hasLength(3)));
    expect(http.headers['authorization'], isNot(contains('.')));
    final decoded = jsonDecode(http.body) as Map<String, Object?>;
    expect(decoded['message'], isNotNull);
    expect(jsonEncode(decoded), jsonEncode(opaque.body));

    expect(
      buildFcmSendHttp(
        const FcmOpaqueRequest(
          host: kFcmSendHost,
          path: '/v1/projects/orbits/messages:send',
          headers: {'authorization': 'bearer aaa.bbb.ccc'},
          body: {'message': <String, Object?>{}},
        ),
      ),
      isNull,
    );
    expect(
      buildFcmSendHttp(
        const FcmOpaqueRequest(
          host: kFcmSendHost,
          path: '/v1/projects/orbits/messages:send',
          headers: {'authorization': 'bearer ya29-opaque'},
          body: {
            'message': {
              'data': {'peerId': 'ORBIT-AA'},
            },
          },
        ),
      ),
      isNull,
    );
    expect(
      buildFcmSendHttp(
        const FcmOpaqueRequest(
          host: kFcmSendHost,
          path: '/v1/projects/orbits/messages:send',
          headers: {
            'authorization': 'bearer ya29-opaque',
            'rootKey': 'nope',
          },
          body: {'message': <String, Object?>{}},
        ),
      ),
      isNull,
    );
    expect(
      buildFcmSendHttp(
        const FcmOpaqueRequest(
          host: kFcmSendHost,
          path: '/v1/projects/orbits/messages:send',
          headers: {
            'authorization': 'bearer ya29-opaque',
            'identity-signing-v1': 'nope',
          },
          body: {'message': <String, Object?>{}},
        ),
      ),
      isNull,
    );
    expect(
      buildFcmSendHttp(
        const FcmOpaqueRequest(
          host: kFcmSendHost,
          path: '/v1/projects/orbits/messages:send',
          headers: {
            'authorization': 'bearer ya29-opaque',
            'opaqueWakeToken': 'tok',
          },
          body: {'message': <String, Object?>{}},
        ),
      ),
      isNull,
    );
    expect(
      buildFcmSendHttp(
        const FcmOpaqueRequest(
          host: kFcmSendHost,
          path: '/v1/projects/orbits/messages:send',
          headers: {'authorization': 'bearer ya29-opaque'},
          body: {
            'message': {
              'data': {'fileKey': 'nope'},
            },
          },
        ),
      ),
      isNull,
    );
    expect(
      buildFcmSendHttp(
        const FcmOpaqueRequest(
          host: kFcmSendHost,
          path: '/v1/projects/orbits/messages:send',
          headers: {'authorization': 'bearer ya29-opaque'},
          body: {
            'message': {
              'data': {'discoverySecret': 'nope'},
            },
          },
        ),
      ),
      isNull,
    );
    expect(
      buildFcmSendHttp(
        const FcmOpaqueRequest(
          host: kFcmSendHost,
          path: '/v1/projects/orbits/messages:send',
          headers: {'authorization': 'bearer ya29-opaque'},
          body: {
            'message': {
              'data': {'vaultKek': 'nope'},
            },
          },
        ),
      ),
      isNull,
    );
    expect(
      buildFcmSendHttp(
        const FcmOpaqueRequest(
          host: kFcmSendHost,
          path: '/v1/projects/orbits/messages:send',
          headers: {
            'authorization': 'bearer ya29-opaque',
            'discoverySecret': 'nope',
          },
          body: {'message': <String, Object?>{}},
        ),
      ),
      isNull,
    );
    expect(
      buildFcmSendHttp(
        const FcmOpaqueRequest(
          host: 'evil.example',
          path: '/v1/projects/orbits/messages:send',
          headers: {'authorization': 'bearer ya29-opaque'},
          body: {'message': <String, Object?>{}},
        ),
      ),
      isNull,
    );
    expect(
      buildFcmSendHttp(
        const FcmOpaqueRequest(
          host: kFcmSendHost,
          path: '/v1/projects/https://evil.example/messages:send',
          headers: {'authorization': 'bearer ya29-opaque'},
          body: {'message': <String, Object?>{}},
        ),
      ),
      isNull,
    );

    var postCount = 0;
    Uri? postedUri;
    Map<String, String>? postedHeaders;
    String? postedBody;
    Future<int> fakePost(
      Uri uri,
      Map<String, String> headers,
      String body,
    ) async {
      postCount++;
      postedUri = uri;
      postedHeaders = headers;
      postedBody = body;
      return 200;
    }

    const sender = PushSender();
    final refused = await sender.sendFcm(
      deviceToken: 'ftok',
      wake: wake,
      accessToken: 'ya29-opaque',
      post: fakePost,
    );
    expect(refused.sent, isFalse);
    expect(refused.reason, 'fcm-not-deployed');
    expect(postCount, 0);
    expect(kLiveFcmGateway, isFalse);

    final dispatched = await dispatchFcmSendHttp(
      request: opaque,
      post: fakePost,
    );
    expect(dispatched.sent, isTrue);
    expect(dispatched.reason, 'fcm-http');
    expect(postCount, 1);
    expect(postedUri!.scheme, 'https');
    expect(postedUri!.host, 'fcm.googleapis.com');
    expect(postedUri!.path, contains('messages:send'));
    expect(postedHeaders!['content-type'], 'application/json');
    expect(postedHeaders!['authorization'], 'bearer ya29-opaque');
    expect(postedBody, http.body);

    final refusedAgain = await sender.sendFcm(
      deviceToken: 'ftok',
      wake: wake,
      accessToken: 'ya29-opaque',
      post: fakePost,
    );
    expect(refusedAgain.reason, 'fcm-not-deployed');
    expect(postCount, 1);

    final notOk = await dispatchFcmSendHttp(
      request: opaque,
      post: (uri, headers, body) async => 403,
    );
    expect(notOk.sent, isFalse);
    expect(notOk.reason, 'http-403');

    expect(
      File('lib/push/fcm_send_http.dart').readAsStringSync(),
      isNot(contains('HttpClient')),
    );
    expect(
      File('lib/push/fcm_send_http.dart').readAsStringSync(),
      contains('Never opens a socket'),
    );
    expect(kLiveFcmGateway, isFalse);
  });
}
