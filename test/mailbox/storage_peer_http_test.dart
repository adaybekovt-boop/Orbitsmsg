import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/storage_peer_http.dart';
import 'package:orbits_flutter/transport/fleet_status.dart';

void main() {
  test('HTTP mailbox rejects oversized bodies and rate-limits deposits', () async {
    final http = StoragePeerHttp(
      BlindMailboxStore(),
      maxBodyBytes: 64,
      rateLimit: 2,
      rateWindowMs: 60 * 1000,
    );
    http.grant(
      MailboxCapability(
        token: 'cap-1',
        quotaBytes: 1024,
        retentionMs: 60 * 1000,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
      ),
    );
    await http.start();
    addTearDown(http.stop);
    expect(http.origin, startsWith('http://127.0.0.1:'));
    expect(localStoragePeerOriginIsLoopback(http.origin), isTrue);

    Future<int> put({required String b64, int seq = 0}) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse('${http.origin}/v1/blocks'));
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({
            'token': 'cap-1',
            'writerKey': 'w',
            'seq': seq,
            'b64': b64,
          }),
        );
        final res = await req.close();
        await res.drain();
        return res.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    expect(await put(b64: base64Encode(const [1])), 200);
    expect(await put(b64: base64Encode(const [2]), seq: 1), 200);
    expect(await put(b64: base64Encode(const [3]), seq: 2), 429);

    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('${http.origin}/v1/blocks'));
      req.headers.contentType = ContentType.json;
      req.write('{${'x' * 80}}');
      final res = await req.close();
      await res.drain();
      expect(res.statusCode, 413);
    } finally {
      client.close(force: true);
    }
  });

  test('HTTP mailbox JS and Dart body caps stay in sync', () {
    final js = File('tool/storage_peer/server.js').readAsStringSync();
    expect(js, contains('MAX_BODY_BYTES = 256 * 1024'));
    expect(js, contains('RATE_LIMIT = 32'));
    expect(js, contains('RATE_WINDOW_MS = 10 * 1000'));
    expect(kMailboxHttpMaxBodyBytes, 256 * 1024);
    expect(kMailboxHttpRateLimit, 32);
    expect(kMailboxHttpRateWindowMs, 10 * 1000);
  });

  test('HTTP mailbox JS FORBIDDEN stays in sync with Dart mailbox keys', () {
    final js = File('tool/storage_peer/server.js').readAsStringSync();
    final start = js.indexOf('const FORBIDDEN');
    expect(start, greaterThanOrEqualTo(0));
    final end = js.indexOf(']', start);
    expect(end, greaterThan(start));
    final region = js.substring(start, end + 1);
    expect(region, contains('fileKey'));
    expect(region, contains('discoverySecret'));
    expect(region, isNot(contains("'b64'")));
  });

  test('HTTP mailbox rejects deposit bodies with fileKey', () async {
    final http = StoragePeerHttp(BlindMailboxStore());
    http.grant(
      MailboxCapability(
        token: 'cap-file',
        quotaBytes: 1024,
        retentionMs: 60 * 1000,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
      ),
    );
    await http.start();
    addTearDown(http.stop);

    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('${http.origin}/v1/blocks'));
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'token': 'cap-file',
          'writerKey': 'w',
          'seq': 0,
          'b64': 'YQ==',
          'fileKey': 'must-not-persist',
        }),
      );
      final res = await req.close();
      await res.drain();
      expect(res.statusCode, 400);
    } finally {
      client.close(force: true);
    }
  });

  test('kLiveStorageFleet stays false', () {
    expect(kLiveStorageFleet, isFalse);
  });

  test('localStoragePeerOriginIsLoopback allows only loopback HTTP', () {
    expect(localStoragePeerOriginIsLoopback('http://127.0.0.1'), isTrue);
    expect(localStoragePeerOriginIsLoopback('http://127.0.0.1:8080'), isTrue);
    expect(localStoragePeerOriginIsLoopback('http://localhost'), isTrue);
    expect(localStoragePeerOriginIsLoopback('http://localhost:9'), isTrue);
    expect(localStoragePeerOriginIsLoopback('http://[::1]'), isTrue);
    expect(localStoragePeerOriginIsLoopback('http://[::1]:1'), isTrue);

    expect(localStoragePeerOriginIsLoopback(''), isFalse);
    expect(localStoragePeerOriginIsLoopback('https://evil'), isFalse);
    expect(localStoragePeerOriginIsLoopback('https://evil.example/v1'), isFalse);
    expect(localStoragePeerOriginIsLoopback('ftp://x'), isFalse);
    expect(localStoragePeerOriginIsLoopback('file://'), isFalse);
    expect(localStoragePeerOriginIsLoopback('example.com'), isFalse);
    expect(localStoragePeerOriginIsLoopback('http://example.com'), isFalse);
    expect(localStoragePeerOriginIsLoopback('https://127.0.0.1'), isFalse);
    expect(
      localStoragePeerOriginIsLoopback('http://127.0.0.1.example.com'),
      isFalse,
    );
  });

  test(
    'httpStoragePeerClient refuses public origin before HttpClient',
    () async {
      expect(kLiveStorageFleet, isFalse);
      var httpClientBuilt = false;
      await HttpOverrides.runZoned(
        () async {
          final client = httpStoragePeerClient('https://evil.example/v1');
          const cap = MailboxCapability(
            token: 't',
            quotaBytes: 1,
            retentionMs: 1,
            expiresAt: 1,
          );
          const block = EncryptedBlock(seq: 0, bytes: <int>[], storedAt: 0);

          await expectLater(
            client.put(token: 't', writerKey: 'w', block: block),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            client.get(token: 't', writerKey: 'w'),
            throwsA(isA<StateError>()),
          );
          await expectLater(client.grant(cap), throwsA(isA<StateError>()));
          await expectLater(
            client.tombstone('t', 'w', 0),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            client.stats(token: 't', writerKey: 'w'),
            throwsA(isA<StateError>()),
          );
        },
        createHttpClient: (context) {
          httpClientBuilt = true;
          fail('HttpClient must not be constructed for a public mailbox origin');
        },
      );
      expect(httpClientBuilt, isFalse);
    },
  );
}
