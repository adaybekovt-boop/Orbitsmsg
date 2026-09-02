import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/storage_peer_http.dart';

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
      req.write('{' + 'x' * 80 + '}');
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
}
