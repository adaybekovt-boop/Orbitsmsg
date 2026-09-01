import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/push/opaque_wake.dart';
import 'package:orbits_flutter/push/push_gateway.dart';
import 'package:orbits_flutter/push/push_registration.dart';
import 'package:orbits_flutter/push/push_send.dart';

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
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('app.orbits/push');
    var invoked = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      invoked += 1;
      return null;
    });
    final reg = PushRegistration(channel: channel);
    expect(reg.shouldRegisterNative, isFalse);
    await reg.registerNativeIfDeployed();
    expect(invoked, 0);
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
}
