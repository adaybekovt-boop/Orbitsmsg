import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/push/apns_send_http.dart';
import 'package:orbits_flutter/push/opaque_wake.dart';

const _safeToken =
    'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';

const _wake = OpaqueWake(
  opaqueWakeToken: 'tok',
  collapseId: 'c1',
  protocolVersion: 1,
);

void main() {
  test('live APNs gateway stays off', () {
    expect(kLiveApnsGateway, isFalse);
  });

  test('sendApns refuses a safe wake while the gateway is off', () async {
    var posted = 0;
    final result = await const PushSender().sendApns(
      deviceToken: _safeToken,
      wake: _wake,
      post: (uri, headers, body) async {
        posted += 1;
        return 200;
      },
    );
    expect(result.sent, isFalse);
    expect(result.reason, 'apns-not-deployed');
    expect(posted, 0);
  });

  test('sendApns refuses unsafe tokens and never posts', () async {
    var posted = 0;
    Future<int> post(Uri uri, Map<String, String> headers, String body) async {
      posted += 1;
      return 200;
    }

    for (final token in <String>[
      '',
      'https://example.test/device',
      'peerId-looks-like-a-token',
      'fileKey-looks-like-a-token',
      'rootKey-looks-like-a-token',
      'discoverySecret-looks-like-a-token',
    ]) {
      final result = await const PushSender().sendApns(
        deviceToken: token,
        wake: _wake,
        post: post,
      );
      expect(result.sent, isFalse, reason: token);
      expect(result.reason, 'unsafe-keys', reason: token);
    }
    expect(posted, 0);
  });

  test('buildApnsRequest is opaque and never carries message metadata', () {
    final request = buildApnsRequest(
      deviceToken: _safeToken,
      wake: _wake,
      nowUnix: 1_700_000_000,
      expirationUnix: 1_700_086_400,
      apnsId: '11111111-2222-3333-4444-555555555555',
    );
    expect(request, isNotNull);
    expect(request!.host, kApnsProductionHost);
    expect(request.path, '/3/device/$_safeToken');
    expect(request.headers['apns-push-type'], 'background');
    expect(request.headers['apns-topic'], kApnsTopic);
    expect(request.headers['apns-id'], '11111111-2222-3333-4444-555555555555');
    expect(request.headers['apns-collapse-id'], 'c1');
    expect(request.body['aps'], {'content-available': 1});
    expect(request.body['opaqueWakeToken'], 'tok');
    expect(request.body.containsKey('peerId'), isFalse);
    expect(request.body.containsKey('conversationId'), isFalse);
    expect(request.body.containsKey('text'), isFalse);
    expect(request.body.containsKey('fileName'), isFalse);
    expect(request.headers.values.join(), isNot(contains('peerId')));
  });

  test('buildApnsSendHttp encodes POST shape without sending', () {
    final request = buildApnsRequest(
      deviceToken: _safeToken,
      wake: _wake,
      sandbox: true,
    );
    final http = buildApnsSendHttp(request!);
    expect(http, isNotNull);
    expect(http!.method, 'POST');
    expect(http.host, kApnsSandboxHost);
    expect(http.path, '/3/device/$_safeToken');
    expect(http.headers['content-type'], 'application/json');
    expect(http.body, contains('"content-available":1'));
    expect(http.body, isNot(contains('peerId')));
  });

  test('buildApnsSendHttp rejects forbidden body keys', () {
    const request = ApnsOpaqueRequest(
      host: kApnsProductionHost,
      path: '/3/device/$_safeToken',
      headers: {'apns-topic': kApnsTopic},
      body: <String, Object?>{
        'aps': <String, Object?>{'content-available': 1},
        'opaqueWakeToken': 'tok',
        'collapseId': 'c1',
        'protocolVersion': 1,
        'peerId': 'ORBIT-AAAAAAAAAAAAAAAA',
      },
    );
    expect(buildApnsSendHttp(request), isNull);
  });

  test('dispatchApnsSendHttp uses only the injected post', () async {
    final request = buildApnsRequest(deviceToken: _safeToken, wake: _wake);
    Uri? seenUri;
    String? seenBody;
    final result = await dispatchApnsSendHttp(
      request: request!,
      post: (uri, headers, body) async {
        seenUri = uri;
        seenBody = body;
        return 200;
      },
    );
    expect(result.sent, isTrue);
    expect(result.reason, 'apns-http');
    expect(seenUri?.scheme, 'https');
    expect(seenUri?.host, kApnsProductionHost);
    expect(seenBody, contains('opaqueWakeToken'));
    expect(seenBody, isNot(contains('peerId')));
  });

  test(
    'PushSender.sendApns does not call dispatch while the flag is off',
    () async {
      var dispatched = 0;
      final result = await const PushSender().sendApns(
        deviceToken: _safeToken,
        wake: _wake,
        post: (uri, headers, body) async {
          dispatched += 1;
          return 200;
        },
      );
      expect(kLiveApnsGateway, isFalse);
      expect(result.reason, 'apns-not-deployed');
      expect(dispatched, 0);
    },
  );
}
