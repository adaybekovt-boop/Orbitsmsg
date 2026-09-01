import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/push/opaque_wake.dart';
import 'package:orbits_flutter/push/push_gateway.dart';
import 'package:orbits_flutter/push/push_registration.dart';
import 'package:orbits_flutter/push/push_send.dart';

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
}
