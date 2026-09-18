import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/mailbox_capability.dart';
import 'package:orbits_flutter/mailbox/storage_peer_client.dart';
import 'package:orbits_flutter/mailbox/storage_peer_http.dart';
import 'package:orbits_flutter/transport/fleet_status.dart';

import 'mailbox_test_support.dart';

void main() {
  test('HTTP mailbox rejects oversized bodies and rate-limits deposits', () async {
    final owner = await deriveFreshMailbox();
    final store = BlindMailboxStore();
    registerCaps(store, owner.caps, quotaBytes: 1024 * 1024);
    final http = StoragePeerHttp(
      store,
      maxBodyBytes: 512,
      rateLimit: 2,
      rateWindowMs: 60 * 1000,
      adminToken: 'lab-admin',
    );
    await http.start();
    addTearDown(http.stop);
    expect(http.origin, startsWith('http://127.0.0.1:'));
    expect(localStoragePeerOriginIsLoopback(http.origin), isTrue);

    Future<int> put(List<int> bytes) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse('${http.origin}/v1/blocks'));
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({
            'queueId': owner.caps.queueId,
            'depositCap': mailboxBytesToHex(owner.caps.depositCap),
            'block': {
              'bytes': base64Encode(bytes),
              'blockHash': sha256HexOf(bytes),
            },
          }),
        );
        final res = await req.close();
        await res.drain();
        return res.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    expect(await put(const [1]), 200);
    expect(await put(const [2]), 200);
    expect(await put(const [3]), 429);

    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('${http.origin}/v1/blocks'));
      req.headers.contentType = ContentType.json;
      req.write('{${'x' * 600}}');
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
    expect(region, contains('writerKey'));
    expect(region, contains('peerId'));
    expect(region, isNot(contains("'b64'")));
  });

  test('kLiveStorageFleet stays false', () {
    expect(kLiveStorageFleet, isFalse);
  });

  test('HTTP stranger/depositor read tombstone stats are 403', () async {
    final owner = await deriveFreshMailbox();
    final stranger = await deriveFreshMailbox();
    final store = BlindMailboxStore();
    registerCaps(store, owner.caps);
    final http = StoragePeerHttp(store, adminToken: 'lab-admin');
    await http.start();
    addTearDown(http.stop);
    store.put(
      queueId: owner.caps.queueId,
      depositCap: owner.caps.depositCap,
      bytes: Uint8List.fromList(const [1, 2, 3]),
      blockHash: sha256HexOf(const [1, 2, 3]),
    );

    Future<int> get(String path) async {
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse('${http.origin}$path'));
        final res = await req.close();
        await res.drain();
        return res.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    Future<int> post(String path, Map<String, Object?> body) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse('${http.origin}$path'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
        final res = await req.close();
        await res.drain();
        return res.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    final depositHex = mailboxBytesToHex(owner.caps.depositCap);
    final strangerHex = mailboxBytesToHex(stranger.caps.readCap);
    expect(
      await get(
        '/v1/blocks?queueId=${owner.caps.queueId}&readCap=$depositHex',
      ),
      403,
    );
    expect(
      await get(
        '/v1/stats?queueId=${owner.caps.queueId}&readCap=$strangerHex',
      ),
      403,
    );
    expect(
      await post('/v1/tombstone', {
        'queueId': owner.caps.queueId,
        'readCap': strangerHex,
        'seq': 1,
      }),
      403,
    );
    expect(store.pendingCount(owner.caps.queueId), 1);
  });

  test('unauthenticated grant and re-register without readCap are 403', () async {
    final owner = await deriveFreshMailbox();
    final http = StoragePeerHttp(
      BlindMailboxStore(requireAdminForFirstGrant: true),
      adminToken: 'lab-admin',
    );
    await http.start();
    addTearDown(http.stop);

    Future<int> grant({String? admin, String? readCap}) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse('${http.origin}/v1/grant'));
        req.headers.contentType = ContentType.json;
        if (admin != null) req.headers.set(kMailboxAdminHeader, admin);
        req.write(
          jsonEncode({
            'queueId': owner.caps.queueId,
            'readCapHash': owner.caps.readCapHashHex,
            'depositCapHash': owner.caps.depositCapHashHex,
            'expiresAt': DateTime.now().millisecondsSinceEpoch + 60 * 1000,
            if (readCap != null) 'readCap': readCap,
          }),
        );
        final res = await req.close();
        await res.drain();
        return res.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    expect(await grant(), 403);
    expect(await grant(admin: 'lab-admin'), 200);
    expect(await grant(admin: 'lab-admin'), 403);
    expect(
      await grant(
        admin: 'lab-admin',
        readCap: mailboxBytesToHex(owner.caps.readCap),
      ),
      200,
    );
  });

  test('HTTP client round-trip and captured bodies stay protocol-only', () async {
    final owner = await deriveFreshMailbox();
    final store = BlindMailboxStore();
    registerCaps(store, owner.caps);
    final http = StoragePeerHttp(store, adminToken: 'lab-admin');
    await http.start();
    addTearDown(http.stop);
    final captured = <String>[];
    final client = httpStoragePeerClient(http.origin, adminToken: 'lab-admin');
    final wrapped = StoragePeerClient(
      putRemote: ({
        required queueId,
        required depositCap,
        required bytes,
        required blockHash,
      }) async {
        captured.add(
          jsonEncode({
            'queueId': queueId,
            'depositCap': mailboxBytesToHex(depositCap),
            'block': {
              'bytes': base64Encode(bytes),
              'blockHash': blockHash,
            },
          }),
        );
        return client.put(
          queueId: queueId,
          depositCap: depositCap,
          bytes: bytes,
          blockHash: blockHash,
        );
      },
      getRemote: ({required queueId, required readCap, fromSeq = 0}) {
        return client.get(
          queueId: queueId,
          readCap: readCap,
          fromSeq: fromSeq,
        );
      },
    );
    await wrapped.put(
      queueId: owner.caps.queueId,
      depositCap: owner.caps.depositCap,
      bytes: const [7, 7, 7],
    );
    expect(captured, hasLength(1));
    final body = jsonDecode(captured.single) as Map<String, Object?>;
    expect(storagePeerKeysAreSafe(body), isTrue);
    expect(body.containsKey('peerId'), isFalse);
    expect(body.containsKey('conversationId'), isFalse);
    expect(body.containsKey('writerKey'), isFalse);
    expect(jsonEncode(body), isNot(contains('discoverySecret')));
    expect(jsonEncode(body), isNot(contains('fileKey')));
  });

  test('httpStoragePeerClient grants with admin and reads with readCap', () async {
    final owner = await deriveFreshMailbox();
    final store = BlindMailboxStore(requireAdminForFirstGrant: true);
    final http = StoragePeerHttp(store, adminToken: 'lab-admin');
    await http.start();
    addTearDown(http.stop);
    final client = httpStoragePeerClient(http.origin, adminToken: 'lab-admin');
    await client.grant(
      cap: MailboxCapability(
        queueId: owner.caps.queueId,
        readCapHash: owner.caps.readCapHashHex,
        depositCapHash: owner.caps.depositCapHashHex,
        quotaBytes: 4096,
        retentionMs: 60 * 1000,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
      ),
      adminToken: 'lab-admin',
    );
    await client.put(
      queueId: owner.caps.queueId,
      depositCap: owner.caps.depositCap,
      bytes: const [1, 2, 3, 4],
    );
    final blocks = await client.get(
      queueId: owner.caps.queueId,
      readCap: owner.caps.readCap,
    );
    expect(blocks.single.bytes, [1, 2, 3, 4]);
  });
}
